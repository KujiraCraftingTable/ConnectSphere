import Vapor
import SQLKit

/// Bearer-token authentication.
/// - `Authorization: Bearer <jwt>` → HS256 verify with `JWT_SECRET`.
/// - Extra round-trip (`Session.isLive`): a soft-deleted (or vanished) account's
///   token, or one issued before a password reset, is rejected immediately with
///   the *same* message as a bad token, so account status isn't leaked.
/// - On success: `req.userID = payload.sub`.
struct AuthMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        let header = request.headers.first(name: .authorization) ?? ""
        guard header.hasPrefix("Bearer ") else {
            throw InlineError(.unauthorized, "No token")
        }
        let token = String(header.dropFirst(7))

        let secret = request.application.appEnv.jwt.secret
        let payload: JWTHS256.Payload
        do {
            payload = try JWTHS256.verify(token, secret: secret)
        } catch {
            throw InlineError(.unauthorized, "Invalid or expired token")
        }

        guard let standing = try await Session.standing(payload, on: request.db.sql()) else {
            throw InlineError(.unauthorized, "Invalid or expired token")
        }
        // Bans are per mode (migration 106): banned in the mode the app is in,
        // only the ban notice, appeals and switching mode stay open.
        if let message = Self.refusal(bannedModes: standing.bannedModes,
                                      requestMode: request.headers.first(name: Self.modeHeader),
                                      queryMode: try? request.query.get(String.self, at: "mode"),
                                      path: request.url.path) {
            throw InlineError(.forbidden, message)
        }
        request.bannedModes = standing.bannedModes
        request.restrictedModes = standing.restrictedModes.filter { $0.value > Date() }
        // Restrictions are per mode (migration 125): the app's mode decides
        // which one a request faces; writes into another mode check that one.
        request.restrictedUntil = AccountRestrictions.until(in: request.headers.first(name: Self.modeHeader),
                                                            of: request.restrictedModes)
        request.accountIsNew = UserRateLimiter.isNewAccount(createdAt: standing.createdAt)
        // Restricted in the app's mode: read-only, apart from settings and safety tools.
        if request.restrictedUntil != nil,
           !Restrictions.allows(method: request.method.rawValue, path: request.url.path) {
            throw InlineError(.forbidden, Restrictions.message)
        }

        // Canonicalise to lowercase, Postgres uuid columns decode to an
        // uppercase String via PostgresKit, but `json_build_object` and node-pg
        // both render lowercase, so everything downstream expects lowercase.
        request.userID = payload.sub.lowercased()
        let response = try await next.respond(to: request)
        request.countIfSucceeded(response.status)
        return response
    }

    // MARK: - Bans
    static let bannedMessage = "This account has been suspended for breaking our Community Standards"

    /// Banned in one mode only: the app's requests in that mode get this.
    static let bannedInModeMessage = "This profile has been suspended in this mode for breaking our Community Standards"
    /// The mode the app is in, sent on every request.
    static let modeHeader = "X-App-Mode"

    static func openToBanned(_ path: String) -> Bool {
        path.hasPrefix("/api/appeals") || path.hasPrefix("/api/account-status")
            || path == "/api/auth/me" || path.hasPrefix("/api/auth/logout")
            || path == "/api/users/me/default-mode"
    }

    /// Why a request is refused, or nil. Banned in every mode is the whole
    /// account; banned in one, only requests made in that mode are refused.
    /// The header is the client's own claim, so a banned account that drops it
    /// (or sends junk) is refused outright: the app always sends it. A `mode`
    /// query naming the banned mode is refused whatever the header says;
    /// writes whose mode comes from the body or the target call
    /// `requireNotBanned(in:)` themselves.
    static func refusal(bannedModes: Set<String>, requestMode: String?, queryMode: String? = nil, path: String) -> String? {
        guard !bannedModes.isEmpty, !openToBanned(path) else { return nil }
        if bannedModes.isSuperset(of: AccountBans.modes) { return bannedMessage }
        guard let mode = requestMode?.lowercased(), AccountBans.modes.contains(mode) else { return bannedInModeMessage }
        if bannedModes.contains(mode) { return bannedInModeMessage }
        if let q = queryMode?.lowercased(), bannedModes.contains(q) { return bannedInModeMessage }
        return nil
    }
}

// MARK: - Session checks
/// Whether a verified token still stands for its account.
enum Session {
    /// Pure rule: a token dies with its account, and with a password reset.
    /// `iat` has whole-second precision, so `validAfter` is compared in whole seconds too.
    static func accepts(iat: Int, deletedAt: Date?, validAfter: Int?) -> Bool {
        guard deletedAt == nil else { return false }
        guard let validAfter else { return true }
        return iat >= validAfter
    }

    static func isLive(_ payload: JWTHS256.Payload, on db: any SQLDatabase) async throws -> Bool {
        try await standing(payload, on: db) != nil
    }

    /// What a live token's account is allowed to do; nil when the token is dead.
    struct Standing { let bannedModes: Set<String>; let restrictedModes: [String: Date]; let createdAt: Date }

    static func standing(_ payload: JWTHS256.Payload, on db: any SQLDatabase) async throws -> Standing? {
        struct Row: Decodable {
            let deleted_at: Date?; let valid_after: Int?
            let banned_modes: [String]; let hobby_restricted_until: Date?; let work_restricted_until: Date?
            let created_at: Date
        }
        guard let row = try await db.raw("""
            SELECT deleted_at, FLOOR(EXTRACT(EPOCH FROM sessions_valid_after))::INT AS valid_after,
                   ARRAY(SELECT DISTINCT ab.mode::text FROM account_bans ab WHERE ab.user_id = users.id
                     AND ab.lifted_at IS NULL AND (ab.banned_until IS NULL OR ab.banned_until > NOW())) AS banned_modes,
                   \(unsafeRaw: AccountRestrictions.untilSQL("users.id", mode: "hobby")) AS hobby_restricted_until,
                   \(unsafeRaw: AccountRestrictions.untilSQL("users.id", mode: "work")) AS work_restricted_until,
                   created_at
            FROM users WHERE id = \(uuid: payload.sub)
            """).first(decoding: Row.self),
              accepts(iat: payload.iat, deletedAt: row.deleted_at, validAfter: row.valid_after)
        else { return nil }
        var restricted: [String: Date] = [:]
        restricted["hobby"] = row.hobby_restricted_until
        restricted["work"] = row.work_restricted_until
        return Standing(bannedModes: Set(row.banned_modes), restrictedModes: restricted, createdAt: row.created_at)
    }
}

// MARK: - Request session values
extension Request {
    private struct UserIDKey: StorageKey { typealias Value = String }
    var userID: String {
        get {
            guard let id = storage[UserIDKey.self] else {
                fatalError("userID accessed without AuthMiddleware")
            }
            return id
        }
        set { storage[UserIDKey.self] = newValue }
    }
    var userIDIfPresent: String? { storage[UserIDKey.self] }

    private struct RestrictedModesKey: StorageKey { typealias Value = [String: Date] }
    /// Each mode restricted right now and when it ends, set by AuthMiddleware.
    var restrictedModes: [String: Date] {
        get { storage[RestrictedModesKey.self] ?? [:] }
        set { storage[RestrictedModesKey.self] = newValue }
    }

    private struct RestrictedUntilKey: StorageKey { typealias Value = Date }
    /// The restriction in the mode the app is in, set by AuthMiddleware.
    var restrictedUntil: Date? {
        get { storage[RestrictedUntilKey.self] }
        set { storage[RestrictedUntilKey.self] = newValue }
    }

    private struct AccountIsNewKey: StorageKey { typealias Value = Bool }
    /// True for the first 48 hours (tighter limits, no links to strangers).
    var accountIsNew: Bool {
        get { storage[AccountIsNewKey.self] ?? false }
        set { storage[AccountIsNewKey.self] = newValue }
    }

    private struct BannedModesKey: StorageKey { typealias Value = Set<String> }
    /// Modes this account is banned in, set by AuthMiddleware.
    var bannedModes: Set<String> {
        get { storage[BannedModesKey.self] ?? [] }
        set { storage[BannedModesKey.self] = newValue }
    }

    /// Refuses a write landing in a mode this account is banned in, whatever
    /// mode the app claimed in `X-App-Mode`.
    func requireNotBanned(in mode: String) throws {
        if bannedModes.contains(mode.lowercased()) { throw InlineError(.forbidden, AuthMiddleware.bannedInModeMessage) }
    }

    /// Refuses a write landing in a mode this account is restricted in,
    /// whatever mode the app claimed. Writes in the app's own mode are already
    /// refused by AuthMiddleware (read-only), so this covers the other mode.
    func requireNotRestricted(in mode: String) throws {
        if restrictedModes[mode.lowercased()] != nil { throw InlineError(.forbidden, Restrictions.message) }
    }
}

import Vapor
import SQLKit

/// Bearer-token authentication.
/// - `Authorization: Bearer <jwt>` → HS256 verify with `JWT_SECRET`.
/// - Extra round-trip (`Session.isLive`): a soft-deleted (or vanished) account's
///   token, or one issued before a password reset, is rejected immediately with
///   the *same* message as a bad token, so account status isn't leaked.
/// - On success: `req.userID = payload.sub`.
/// Error bodies use the inline `{ "error": "..." }` shape (all 401).
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
                                      path: request.url.path) {
            throw InlineError(.forbidden, message)
        }
        request.restrictedUntil = standing.restrictedUntil.flatMap { $0 > Date() ? $0 : nil }
        request.accountIsNew = UserRateLimiter.isNewAccount(createdAt: standing.createdAt)

        // Canonicalise to lowercase, Postgres uuid columns decode to an
        // uppercase String via PostgresKit, but `json_build_object` and node-pg
        // both render lowercase, so everything downstream expects lowercase.
        request.userID = payload.sub.lowercased()
        return try await next.respond(to: request)
    }

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
    static func refusal(bannedModes: Set<String>, requestMode: String?, path: String) -> String? {
        guard !bannedModes.isEmpty, !openToBanned(path) else { return nil }
        if bannedModes.isSuperset(of: AccountBans.modes) { return bannedMessage }
        if let mode = requestMode?.lowercased(), bannedModes.contains(mode) { return bannedInModeMessage }
        return nil
    }
}

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
    struct Standing { let bannedModes: Set<String>; let restrictedUntil: Date?; let createdAt: Date }

    static func standing(_ payload: JWTHS256.Payload, on db: any SQLDatabase) async throws -> Standing? {
        struct Row: Decodable {
            let deleted_at: Date?; let valid_after: Int?
            let banned_modes: [String]; let restricted_until: Date?; let created_at: Date
        }
        guard let row = try await db.raw("""
            SELECT deleted_at, FLOOR(EXTRACT(EPOCH FROM sessions_valid_after))::INT AS valid_after,
                   ARRAY(SELECT DISTINCT ab.mode::text FROM account_bans ab WHERE ab.user_id = users.id
                     AND ab.lifted_at IS NULL AND (ab.banned_until IS NULL OR ab.banned_until > NOW())) AS banned_modes,
                   restricted_until, created_at
            FROM users WHERE id = \(uuid: payload.sub)
            """).first(decoding: Row.self),
              accepts(iat: payload.iat, deletedAt: row.deleted_at, validAfter: row.valid_after)
        else { return nil }
        return Standing(bannedModes: Set(row.banned_modes), restrictedUntil: row.restricted_until, createdAt: row.created_at)
    }
}

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

    private struct RestrictedUntilKey: StorageKey { typealias Value = Date }
    /// Set by AuthMiddleware while a moderation restriction is running.
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

    /// Stops a restricted account posting, commenting, joining communities or reaching strangers.
    func requireNotRestricted() throws {
        if let until = restrictedUntil { throw InlineError(.forbidden, Restrictions.message(until: until)) }
    }
}

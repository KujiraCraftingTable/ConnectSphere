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

        guard try await Session.isLive(payload, on: request.db.sql()) else {
            throw InlineError(.unauthorized, "Invalid or expired token")
        }

        // Canonicalise to lowercase, Postgres uuid columns decode to an
        // uppercase String via PostgresKit, but `json_build_object` and node-pg
        // both render lowercase, so everything downstream expects lowercase.
        request.userID = payload.sub.lowercased()
        return try await next.respond(to: request)
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
        struct Row: Decodable { let deleted_at: Date?; let valid_after: Int? }
        guard let row = try await db.raw("""
            SELECT deleted_at, FLOOR(EXTRACT(EPOCH FROM sessions_valid_after))::INT AS valid_after
            FROM users WHERE id = \(uuid: payload.sub)
            """).first(decoding: Row.self) else { return false }
        return accepts(iat: payload.iat, deletedAt: row.deleted_at, validAfter: row.valid_after)
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
}

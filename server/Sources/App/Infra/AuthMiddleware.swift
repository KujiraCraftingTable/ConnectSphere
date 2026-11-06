import Vapor
import SQLKit

/// Bearer-token authentication.
/// - `Authorization: Bearer <jwt>` → HS256 verify with `JWT_SECRET`.
/// - Extra round-trip: `SELECT deleted_at FROM users WHERE id = $1`. A
///   soft-deleted (or vanished) account's token is rejected immediately with
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

        struct Row: Decodable { let deleted_at: Date? }
        let row = try await request.db.sql()
            .raw("SELECT deleted_at FROM users WHERE id = \(uuid: payload.sub)")
            .first(decoding: Row.self)
        guard let row, row.deleted_at == nil else {
            throw InlineError(.unauthorized, "Invalid or expired token")
        }

        // Canonicalise to lowercase, Postgres uuid columns decode to an
        // uppercase String via PostgresKit, but `json_build_object` and node-pg
        // both render lowercase, so everything downstream expects lowercase.
        request.userID = payload.sub.lowercased()
        return try await next.respond(to: request)
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

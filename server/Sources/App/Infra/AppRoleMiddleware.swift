import Vapor
import SQLKit

/// After AuthMiddleware: lets only app moderators and admins through
/// (`users.app_role`, migration 089). Looked up per request, so revoking the
/// role takes effect at once. Anyone else gets a 404 — the admin area
/// shouldn't announce itself.
struct AppRoleMiddleware: AsyncMiddleware {
    /// Only the official account (the one admin, migration 104), not moderators.
    var adminOnly = false

    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        struct R: Decodable { let app_role: String }
        let role = try await request.db.sql()
            .raw("SELECT app_role FROM users WHERE id = \(uuid: request.userID)")
            .first(decoding: R.self)?.app_role
        guard role == "admin" || (!adminOnly && role == "moderator") else { throw Abort(.notFound) }
        return try await next.respond(to: request)
    }
}

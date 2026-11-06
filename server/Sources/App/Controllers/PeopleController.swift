import Vapor
import SQLKit

/// `/api/people/suggestions`, People you may know (see `SuggestionStore`).
struct PeopleController {
    static func register(routes: any RoutesBuilder) {
        let p = routes.grouped("people", "suggestions").grouped(AuthMiddleware())
        p.get(use: list)
        p.post(":id", "dismiss", use: dismiss)
    }

    struct ListResponse: Content { var data: [SuggestionStore.Suggestion] }
    struct OK: Content { var ok: Bool }

    static func list(_ req: Request) async throws -> ListResponse {
        let mode = try validMode(try? req.query.get(String.self, at: "mode"))
        let limit = InteractionsController.clampLimit(try? req.query.get(Int.self, at: "limit"),
                                                      SuggestionStore.defaultLimit, SuggestionStore.maxLimit)
        return ListResponse(data: try await SuggestionStore.suggestions(for: req.userID, mode: mode, limit: limit,
                                                                        on: req.db.sql()))
    }

    static func dismiss(_ req: Request) async throws -> OK {
        let mode = try validMode(try? req.query.get(String.self, at: "mode"))
        guard let target = UUID(uuidString: req.parameters.get("id") ?? ""),
              target.uuidString.lowercased() != req.userID.lowercased() else {
            throw InlineError(.badRequest, "Invalid user id")
        }
        let db = req.db.sql()
        struct I: Decodable { let id: String }
        guard try await db.raw("SELECT id::text AS id FROM users WHERE id = \(uuid: target.uuidString) AND deleted_at IS NULL")
            .first(decoding: I.self) != nil else {
            throw InlineError(.notFound, "User not found")
        }
        try await SuggestionStore.dismiss(target.uuidString, by: req.userID, mode: mode, on: db)
        return OK(ok: true)
    }

    static func validMode(_ raw: String?) throws -> String {
        guard let mode = raw, SuggestionStore.modes.contains(mode) else {
            throw InlineError(.badRequest, "mode must be hobby or work")
        }
        return mode
    }
}

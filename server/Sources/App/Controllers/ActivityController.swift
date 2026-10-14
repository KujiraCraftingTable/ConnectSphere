import Vapor
import SQLKit

/// GET /users/me/activity?type=comments|reactions&offset=0&limit=30 — paged by
/// offset: the timestamps go out at millisecond precision, too coarse for a
/// "before" cursor.
struct ActivityController {
    static func register(routes: any RoutesBuilder) {
        routes.grouped("users", "me").grouped(AuthMiddleware()).get("activity", use: list)
    }

    static func list(_ req: Request) async throws -> DataListResponse<ActivityStore.Item> {
        let type = (try? req.query.get(String.self, at: "type")) ?? "comments"
        guard ["comments", "reactions"].contains(type) else {
            throw Abort(.badRequest, reason: "type must be comments or reactions")
        }
        let limit = PostsController.clamp(try? req.query.get(Int.self, at: "limit"), 30, 1, 50)
        let offset = max((try? req.query.get(Int.self, at: "offset")) ?? 0, 0)
        let db = req.db.sql()
        let items = type == "comments"
            ? try await ActivityStore.comments(of: req.userID, offset: offset, limit: limit, on: db)
            : try await ActivityStore.reactions(of: req.userID, offset: offset, limit: limit, on: db)
        return DataListResponse(data: items)
    }
}

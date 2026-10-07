import Vapor
import SQLKit

/// Follow / unfollow (instant, per mode, independent of friendship) and the
/// followers / following lists (friends excluded — see FollowStore).
struct FollowsController {
    static func register(routes: any RoutesBuilder) {
        let f = routes.grouped("follows").grouped(AuthMiddleware())
        f.post(":userId", use: follow)
        f.delete(":userId", use: unfollow)
        f.get(":userId", use: list)
    }

    struct FollowState: Content { var is_following: Bool }

    private static func mode(_ req: Request) throws -> String {
        guard let m = try? req.query.get(String.self, at: "mode"), FollowStore.modes.contains(m) else {
            throw InlineError(.badRequest, "mode must be hobby or work")
        }
        return m
    }

    static func follow(_ req: Request) async throws -> FollowState {
        let target = req.parameters.get("userId")!
        let mode = try mode(req)
        guard target != req.userID else { throw InlineError(.badRequest, "Cannot follow yourself") }
        let db = req.db.sql()
        struct I: Decodable { let id: String }
        guard try await db.raw("SELECT id::text AS id FROM users WHERE id = \(uuid: target) AND deleted_at IS NULL")
            .first(decoding: I.self) != nil else { throw InlineError(.notFound, "User not found") }
        guard try await !UserStore.isBlockedEitherWay(req.userID, target, on: db) else {
            throw InlineError(.forbidden, "Cannot follow this user")
        }
        try await FollowStore.follow(req.userID, target, mode: mode, on: db)
        return FollowState(is_following: true)
    }

    static func unfollow(_ req: Request) async throws -> FollowState {
        try await FollowStore.unfollow(req.userID, req.parameters.get("userId")!, mode: try mode(req), on: req.db.sql())
        return FollowState(is_following: false)
    }

    struct ListResponse: Content { var data: [FollowStore.Person] }

    static func list(_ req: Request) async throws -> ListResponse {
        let type = (try? req.query.get(String.self, at: "type")) ?? "followers"
        guard ["followers", "following"].contains(type) else {
            throw InlineError(.badRequest, "type must be followers or following")
        }
        let limit = PostsController.clamp(try? req.query.get(Int.self, at: "limit"), 50, 1, 100)
        let offset = max((try? req.query.get(Int.self, at: "offset")) ?? 0, 0)
        let people = try await FollowStore.list(of: req.parameters.get("userId")!, followers: type == "followers",
                                                mode: try mode(req), limit: limit, offset: offset, on: req.db.sql())
        return ListResponse(data: people)
    }
}

import Vapor
import SQLKit

/// Skills on a Work profile and endorsing them.
struct EndorsementsController {
    static func register(routes: any RoutesBuilder) {
        let u = routes.grouped("users").grouped(AuthMiddleware())
        u.get(":id", "skills", use: list)
        u.post(":id", "skills", ":skillId", "endorse", use: endorse)
        u.delete(":id", "skills", ":skillId", "endorse", use: unendorse)
    }

    private static func target(_ req: Request) throws -> String {
        var id = req.parameters.get("id")!
        if id == "me" { id = req.userID }
        guard UUID(uuidString: id) != nil else { throw Abort(.notFound) }
        return id.lowercased()
    }

    /// The skills, and whether the viewer may endorse them (a Work
    /// connection, not themselves), so the app only offers it then.
    struct SkillsResponse: Content {
        var data: [EndorsementStore.Skill]
        var can_endorse: Bool
    }

    private static func response(for user: String, _ req: Request) async throws -> SkillsResponse {
        let db = req.db.sql()
        let me = req.userID.lowercased()
        let can = user != me ? try await EndorsementStore.areWorkConnections(me, user, on: db) : false
        return SkillsResponse(data: try await EndorsementStore.skills(of: user, viewer: me, on: db), can_endorse: can)
    }

    static func list(_ req: Request) async throws -> SkillsResponse {
        let user = try target(req)
        return try await response(for: user, req)
    }

    /// Only a Work connection, never yourself, and only for a skill that
    /// person lists.
    private static func checked(_ req: Request) async throws -> (user: String, skillID: Int, skill: String) {
        let user = try target(req)
        guard user != req.userID.lowercased() else { throw Abort(.forbidden, reason: "You can't endorse your own skills") }
        guard let skillID = req.parameters.get("skillId", as: Int.self) else { throw Abort(.notFound) }
        let db = req.db.sql()
        guard let name = try await EndorsementStore.skill(skillID, of: user, on: db) else {
            throw Abort(.notFound, reason: "Skill not found")
        }
        guard try await EndorsementStore.areWorkConnections(req.userID, user, on: db) else {
            throw Abort(.forbidden, reason: "Only your Work connections can endorse skills")
        }
        return (user, skillID, name)
    }

    static func endorse(_ req: Request) async throws -> SkillsResponse {
        let (user, skillID, name) = try await checked(req)
        let db = req.db.sql()
        if try await EndorsementStore.endorse(skillID, by: req.userID, on: db) {
            let actor = req.userID
            NotifyService.fireAndForget(req) { d, h, l in
                var payload = (try? await NotifyService.actorPayload(actor, mode: "work", on: d)) ?? ["fromUserId": actor]
                payload["skill"] = name
                payload["mode"] = "work"
                _ = await NotifyService.pushUserNotification(
                    userID: user, type: "skill_endorsed", actorID: actor, entityType: "user", entityID: actor,
                    payload: payload, on: d, hub: h, logger: l)
            }
        }
        return try await response(for: user, req)
    }

    static func unendorse(_ req: Request) async throws -> SkillsResponse {
        let (user, skillID, _) = try await checked(req)
        try await EndorsementStore.unendorse(skillID, by: req.userID, on: req.db.sql())
        return try await response(for: user, req)
    }
}

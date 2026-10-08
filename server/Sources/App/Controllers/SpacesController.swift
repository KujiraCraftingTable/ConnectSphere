import Vapor
import SQLKit

/// `/api/spaces` — the signed-in user's own chat spaces (see `SpaceStore`).
/// Another user's space id behaves exactly like a missing one (404).
struct SpacesController {
    static func register(routes: any RoutesBuilder) {
        let s = routes.grouped("spaces").grouped(AuthMiddleware())
        s.get(use: list)
        s.post(use: create)
        s.patch(":id", use: update)
        s.delete(":id", use: delete)
        s.put(":id", "members", use: setMembers)
        s.post(":id", "members", ":userId", use: addMember)
        s.delete(":id", "members", ":userId", use: removeMember)
        s.post(":id", "groups", ":conversationId", use: addGroup)
        s.delete(":id", "groups", ":conversationId", use: removeGroup)
    }

    struct ListResponse: Content { var data: [SpaceStore.Space] }
    struct OK: Content { var ok: Bool }

    static func list(_ req: Request) async throws -> ListResponse {
        guard let mode = try? req.query.get(String.self, at: "mode"), SpaceStore.modes.contains(mode) else {
            throw InlineError(.badRequest, "mode must be hobby or work")
        }
        return ListResponse(data: try await SpaceStore.list(owner: req.userID, mode: mode, on: req.db.sql()))
    }

    struct CreateBody: Content {
        var name: String?; var mode: String?; var color: String?
        var member_ids: [String]?; var conversation_ids: [String]?
    }

    static func create(_ req: Request) async throws -> SpaceStore.Space {
        let b = try req.content.decode(CreateBody.self)
        guard let mode = b.mode, SpaceStore.modes.contains(mode) else {
            throw InlineError(.badRequest, "mode must be hobby or work")
        }
        let name = try validName(b.name)
        let color = try validColor(b.color ?? "blue")
        let db = req.db.sql()
        guard try await SpaceStore.count(owner: req.userID, mode: mode, on: db) < SpaceStore.maxSpacesPerMode else {
            throw InlineError(.badRequest, "You can have up to \(SpaceStore.maxSpacesPerMode) spaces")
        }
        guard try await !SpaceStore.nameTaken(name, owner: req.userID, mode: mode, on: db) else {
            throw InlineError(.conflict, "You already have a space with that name")
        }
        let members = try await validMembers(b.member_ids ?? [], mode: mode, req)
        let groups = try await validGroups(b.conversation_ids ?? [], mode: mode, req)
        let id = try await SpaceStore.create(owner: req.userID, mode: mode, name: name, color: color, on: db)
        try await SpaceStore.addMembers(id, members, on: db)
        try await SpaceStore.addGroups(id, groups, on: db)
        return try await space(id, req)
    }

    struct UpdateBody: Content { var name: String?; var color: String? }

    static func update(_ req: Request) async throws -> SpaceStore.Space {
        let id = try spaceID(req)
        let b = try req.content.decode(UpdateBody.self)
        let db = req.db.sql()
        guard let mode = try await SpaceStore.mode(of: id, owner: req.userID, on: db) else {
            throw InlineError(.notFound, "Space not found")
        }
        let name = try b.name.map { try validName($0) }
        let color = try b.color.map { try validColor($0) }
        if let name, try await SpaceStore.nameTaken(name, owner: req.userID, mode: mode, excluding: id, on: db) {
            throw InlineError(.conflict, "You already have a space with that name")
        }
        try await SpaceStore.update(id, name: name, color: color, on: db)
        return try await space(id, req)
    }

    static func delete(_ req: Request) async throws -> OK {
        let id = try spaceID(req)
        let db = req.db.sql()
        guard try await SpaceStore.mode(of: id, owner: req.userID, on: db) != nil else {
            throw InlineError(.notFound, "Space not found")
        }
        try await SpaceStore.delete(id, owner: req.userID, on: db)
        return OK(ok: true)
    }

    /// `conversation_ids` absent leaves the space's groups as they are, so an
    /// older client that only knows about people can't wipe them.
    struct MembersBody: Content { var member_ids: [String]?; var conversation_ids: [String]? }

    static func setMembers(_ req: Request) async throws -> SpaceStore.Space {
        let id = try spaceID(req)
        let db = req.db.sql()
        guard let mode = try await SpaceStore.mode(of: id, owner: req.userID, on: db) else {
            throw InlineError(.notFound, "Space not found")
        }
        let body = try req.content.decode(MembersBody.self)
        let members = try await validMembers(body.member_ids ?? [], mode: mode, req)
        var groups: [UUID]?
        if let raw = body.conversation_ids { groups = try await validGroups(raw, mode: mode, req) }
        try await SpaceStore.replaceMembers(id, with: members, on: db)
        if let groups { try await SpaceStore.replaceGroups(id, with: groups, on: db) }
        return try await space(id, req)
    }

    static func addMember(_ req: Request) async throws -> SpaceStore.Space {
        let id = try spaceID(req)
        let db = req.db.sql()
        guard let mode = try await SpaceStore.mode(of: id, owner: req.userID, on: db) else {
            throw InlineError(.notFound, "Space not found")
        }
        guard try await SpaceStore.memberCount(id, on: db) < SpaceStore.maxMembers else {
            throw InlineError(.badRequest, "A space can hold up to \(SpaceStore.maxMembers) people")
        }
        let members = try await validMembers([req.parameters.get("userId") ?? ""], mode: mode, req)
        try await SpaceStore.addMembers(id, members, on: db)
        return try await space(id, req)
    }

    static func removeMember(_ req: Request) async throws -> SpaceStore.Space {
        let id = try spaceID(req)
        let db = req.db.sql()
        guard try await SpaceStore.mode(of: id, owner: req.userID, on: db) != nil else {
            throw InlineError(.notFound, "Space not found")
        }
        guard let member = UUID(uuidString: req.parameters.get("userId") ?? "") else {
            throw InlineError(.badRequest, "Invalid user id")
        }
        try await SpaceStore.removeMember(id, member.uuidString, on: db)
        return try await space(id, req)
    }

    static func addGroup(_ req: Request) async throws -> SpaceStore.Space {
        let id = try spaceID(req)
        let db = req.db.sql()
        guard let mode = try await SpaceStore.mode(of: id, owner: req.userID, on: db) else {
            throw InlineError(.notFound, "Space not found")
        }
        guard try await SpaceStore.groupCount(id, on: db) < SpaceStore.maxGroups else {
            throw InlineError(.badRequest, "A space can hold up to \(SpaceStore.maxGroups) groups")
        }
        let groups = try await validGroups([req.parameters.get("conversationId") ?? ""], mode: mode, req)
        try await SpaceStore.addGroups(id, groups, on: db)
        return try await space(id, req)
    }

    static func removeGroup(_ req: Request) async throws -> SpaceStore.Space {
        let id = try spaceID(req)
        let db = req.db.sql()
        guard try await SpaceStore.mode(of: id, owner: req.userID, on: db) != nil else {
            throw InlineError(.notFound, "Space not found")
        }
        guard let group = UUID(uuidString: req.parameters.get("conversationId") ?? "") else {
            throw InlineError(.badRequest, "Invalid conversation id")
        }
        try await SpaceStore.removeGroup(id, group.uuidString, on: db)
        return try await space(id, req)
    }

    // MARK: Validation

    static func validName(_ raw: String?) throws -> String {
        guard let name = SpaceStore.cleanName(raw) else {
            throw InlineError(.badRequest, "A space name needs 1–\(SpaceStore.maxNameLength) characters")
        }
        return name
    }

    static func validColor(_ raw: String) throws -> String {
        guard SpaceStore.colors.contains(raw) else { throw InlineError(.badRequest, "Unknown space colour") }
        return raw
    }

    /// Parses, de-duplicates and checks the ids: each must be a real person
    /// who isn't you, isn't blocked either way, and is a friend or has a chat
    /// with you that's past the request stage. Any bad id refuses the
    /// whole request rather than silently dropping someone.
    private static func validMembers(_ raw: [String], mode: String, _ req: Request) async throws -> [UUID] {
        var seen = Set<String>()
        var ids: [UUID] = []
        for value in raw {
            guard let id = UUID(uuidString: value) else { throw InlineError(.badRequest, "Invalid user id") }
            if seen.insert(id.uuidString.lowercased()).inserted { ids.append(id) }
        }
        guard ids.count <= SpaceStore.maxMembers else {
            throw InlineError(.badRequest, "A space can hold up to \(SpaceStore.maxMembers) people")
        }
        let allowed = try await SpaceStore.allowedMembers(ids, owner: req.userID, mode: mode, on: req.db.sql())
        guard allowed.count == ids.count else {
            throw InlineError(.badRequest, "Some of these people can't be added to a space")
        }
        return ids
    }

    /// Same all-or-nothing rule for group chats: each must be a group of the
    /// space's mode that you're in.
    private static func validGroups(_ raw: [String], mode: String, _ req: Request) async throws -> [UUID] {
        var seen = Set<String>()
        var ids: [UUID] = []
        for value in raw {
            guard let id = UUID(uuidString: value) else { throw InlineError(.badRequest, "Invalid conversation id") }
            if seen.insert(id.uuidString.lowercased()).inserted { ids.append(id) }
        }
        guard ids.count <= SpaceStore.maxGroups else {
            throw InlineError(.badRequest, "A space can hold up to \(SpaceStore.maxGroups) groups")
        }
        let allowed = try await SpaceStore.allowedGroups(ids, owner: req.userID, mode: mode, on: req.db.sql())
        guard allowed.count == ids.count else {
            throw InlineError(.badRequest, "Some of these groups can't be added to a space")
        }
        return ids
    }

    private static func spaceID(_ req: Request) throws -> String {
        guard let id = UUID(uuidString: req.parameters.get("id") ?? "") else {
            throw InlineError(.notFound, "Space not found")
        }
        return id.uuidString
    }

    private static func space(_ id: String, _ req: Request) async throws -> SpaceStore.Space {
        guard let s = try await SpaceStore.find(id, owner: req.userID, on: req.db.sql()) else {
            throw InlineError(.notFound, "Space not found")
        }
        return s
    }
}

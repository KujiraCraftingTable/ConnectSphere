import Vapor
import SQLKit

/// Chat spaces (migration 038): private, per-mode labels a user puts on people
/// to organise Messages. Every query is scoped to the owner — nobody else can
/// see or touch someone's spaces.
enum SpaceStore {
    static let modes: Set<String> = ["hobby", "work"]
    /// Same keys as the app's `SpaceColor`.
    static let colors: Set<String> = [
        "red", "rose", "coral", "orange", "amber", "yellow", "lime", "olive",
        "green", "forest", "emerald", "teal", "cyan", "sky", "blue", "navy",
        "indigo", "violet", "purple", "fuchsia", "pink", "brown", "slate", "gray",
    ]
    static let maxSpacesPerMode = 20
    static let maxMembers = 200
    static let maxNameLength = 30

    struct Space: Content {
        var id: String
        var name: String
        var color: String
        var position: Int
        var member_ids: [String]
        /// The same people with their name/photo for the space's mode, so a
        /// space can show someone you haven't chatted with yet.
        var members: [Member]
    }

    struct Member: Content {
        var id: String
        var display_name: String
        @NullCoded var avatar_url: String?
        @NullCoded var avatar_color: String?
    }

    /// Raw row: `members` arrives as JSON text and is decoded into `Space`.
    private struct Row: Decodable {
        let id: String; let name: String; let color: String; let position: Int
        let member_ids: [String]; let members: String
    }

    private static func space(_ r: Row) -> Space {
        let members = (try? JSONCoding.makeDecoder().decode([Member].self, from: Data(r.members.utf8))) ?? []
        return Space(id: r.id, name: r.name, color: r.color, position: r.position, member_ids: r.member_ids, members: members)
    }

    /// Columns shared by `list` and `find` (space alias `s`).
    private static var columns: String {
        """
        s.id::text AS id, s.name, s.color, s.position,
          COALESCE((SELECT array_agg(m.user_id::text ORDER BY m.added_at)
                    FROM chat_space_members m JOIN users u ON u.id = m.user_id AND u.deleted_at IS NULL
                    WHERE m.space_id = s.id), '{}') AS member_ids,
          COALESCE((SELECT json_agg(json_build_object(
                      'id', u.id::text,
                      'display_name', \(PersonaSQL.expr("display_name", modeRef: "s.mode")),
                      'avatar_url', \(PersonaSQL.expr("avatar_url", modeRef: "s.mode")),
                      'avatar_color', u.avatar_color) ORDER BY m.added_at)
                    FROM chat_space_members m JOIN users u ON u.id = m.user_id AND u.deleted_at IS NULL
                    WHERE m.space_id = s.id), '[]'::json)::text AS members
        """
    }

    /// The name to store, or nil when it's empty or too long once trimmed.
    static func cleanName(_ raw: String?) -> String? {
        guard let name = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty, name.count <= maxNameLength else { return nil }
        return name
    }

    static func list(owner: String, mode: String, on db: any SQLDatabase) async throws -> [Space] {
        try await db.raw("""
            SELECT \(unsafeRaw: columns)
            FROM chat_spaces s
            WHERE s.owner_id = \(uuid: owner) AND s.mode = \(bind: mode)
            ORDER BY s.position, s.created_at
            """).all(decoding: Row.self).map(space)
    }

    static func find(_ id: String, owner: String, on db: any SQLDatabase) async throws -> Space? {
        try await db.raw("""
            SELECT \(unsafeRaw: columns)
            FROM chat_spaces s
            WHERE s.id = \(uuid: id) AND s.owner_id = \(uuid: owner)
            """).first(decoding: Row.self).map(space)
    }

    static func mode(of id: String, owner: String, on db: any SQLDatabase) async throws -> String? {
        struct M: Decodable { let mode: String }
        return try await db.raw("SELECT mode FROM chat_spaces WHERE id = \(uuid: id) AND owner_id = \(uuid: owner)")
            .first(decoding: M.self)?.mode
    }

    static func count(owner: String, mode: String, on db: any SQLDatabase) async throws -> Int {
        struct N: Decodable { let n: Int }
        return try await db.raw("SELECT COUNT(*)::int AS n FROM chat_spaces WHERE owner_id = \(uuid: owner) AND mode = \(bind: mode)")
            .first(decoding: N.self)?.n ?? 0
    }

    /// Whether the owner already has a space with this name in this mode
    /// (case-insensitive), other than `excluding`.
    static func nameTaken(_ name: String, owner: String, mode: String, excluding: String? = nil,
                          on db: any SQLDatabase) async throws -> Bool {
        struct I: Decodable { let id: String }
        let rows = try await db.raw("""
            SELECT id::text AS id FROM chat_spaces
            WHERE owner_id = \(uuid: owner) AND mode = \(bind: mode) AND lower(name) = lower(\(bind: name))
            """).all(decoding: I.self)
        return rows.contains { $0.id.lowercased() != excluding?.lowercased() }
    }

    /// The ids among `ids` that may sit in the owner's spaces in `mode`: real,
    /// not deleted, not the owner, no block between them either way…
    static func allowedMembers(_ ids: [UUID], owner: String, mode: String, on db: any SQLDatabase) async throws -> Set<String> {
        guard !ids.isEmpty else { return [] }
        struct I: Decodable { let id: String }
        let rows = try await db.raw("""
            SELECT u.id::text AS id FROM users u
            WHERE u.id = ANY(\(bind: ids)) AND u.deleted_at IS NULL AND u.id <> \(uuid: owner)
              AND NOT EXISTS (SELECT 1 FROM user_blocks b
                              WHERE (b.blocker_id = \(uuid: owner) AND b.blocked_id = u.id)
                                 OR (b.blocker_id = u.id AND b.blocked_id = \(uuid: owner)))
            """).all(decoding: I.self)
        // …and someone you're friends with or whose chat is past the request
        // stage — a not-yet-accepted stranger can't be filed (or file you) yet.
        let strangers = try await MessageRequests.unrelated(owner, ids, mode: mode, on: db)
        return Set(rows.map { $0.id.lowercased() }).subtracting(strangers)
    }

    static func create(owner: String, mode: String, name: String, color: String,
                       on db: any SQLDatabase) async throws -> String {
        struct I: Decodable { let id: String }
        return try await db.raw("""
            INSERT INTO chat_spaces (owner_id, mode, name, color, position)
            VALUES (\(uuid: owner), \(bind: mode), \(bind: name), \(bind: color),
                    COALESCE((SELECT MAX(position) + 1 FROM chat_spaces WHERE owner_id = \(uuid: owner) AND mode = \(bind: mode)), 0))
            RETURNING id::text AS id
            """).first(decoding: I.self)!.id
    }

    static func update(_ id: String, name: String?, color: String?, on db: any SQLDatabase) async throws {
        try await db.raw("""
            UPDATE chat_spaces SET name = COALESCE(\(bind: name), name), color = COALESCE(\(bind: color), color)
            WHERE id = \(uuid: id)
            """).run()
    }

    static func delete(_ id: String, owner: String, on db: any SQLDatabase) async throws {
        try await db.raw("DELETE FROM chat_spaces WHERE id = \(uuid: id) AND owner_id = \(uuid: owner)").run()
    }

    static func replaceMembers(_ id: String, with members: [UUID], on db: any SQLDatabase) async throws {
        try await db.raw("DELETE FROM chat_space_members WHERE space_id = \(uuid: id)").run()
        try await addMembers(id, members, on: db)
    }

    static func addMembers(_ id: String, _ members: [UUID], on db: any SQLDatabase) async throws {
        guard !members.isEmpty else { return }
        try await db.raw("""
            INSERT INTO chat_space_members (space_id, user_id)
            SELECT \(uuid: id), unnest(\(bind: members))
            ON CONFLICT DO NOTHING
            """).run()
    }

    static func removeMember(_ id: String, _ member: String, on db: any SQLDatabase) async throws {
        try await db.raw("DELETE FROM chat_space_members WHERE space_id = \(uuid: id) AND user_id = \(uuid: member)").run()
    }

    static func memberCount(_ id: String, on db: any SQLDatabase) async throws -> Int {
        struct N: Decodable { let n: Int }
        return try await db.raw("SELECT COUNT(*)::int AS n FROM chat_space_members WHERE space_id = \(uuid: id)")
            .first(decoding: N.self)?.n ?? 0
    }
}

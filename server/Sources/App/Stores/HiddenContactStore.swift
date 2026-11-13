import Vapor
import SQLKit

/// People the owner hid from the Messages people row (migration 140).
/// Per owner and mode; it never affects the chat itself.
enum HiddenContactStore {
    static let modes: Set<String> = ["hobby", "work"]

    struct Contact: Content {
        var id: String
        var display_name: String
        @NullCoded var avatar_url: String?
        @NullCoded var avatar_color: String?
        var hidden_at: Date
    }

    static func list(owner: String, mode: String, on db: any SQLDatabase) async throws -> [Contact] {
        let dn = PersonaSQL.expr("display_name", modeRef: "h.mode")
        let av = PersonaSQL.expr("avatar_url", modeRef: "h.mode")
        return try await db.raw("""
            SELECT u.id::text AS id, \(unsafeRaw: dn) AS display_name, \(unsafeRaw: av) AS avatar_url,
                   u.avatar_color, h.created_at AS hidden_at
            FROM chat_hidden_contacts h JOIN users u ON u.id = h.hidden_id
            WHERE h.owner_id = \(uuid: owner) AND h.mode = \(bind: mode)
            ORDER BY h.created_at DESC
            """).all(decoding: Contact.self)
    }

    static func userExists(_ id: String, on db: any SQLDatabase) async throws -> Bool {
        struct R: Decodable { let ok: Bool }
        return try await db.raw("SELECT EXISTS (SELECT 1 FROM users WHERE id = \(uuid: id)) AS ok")
            .first(decoding: R.self)?.ok ?? false
    }

    static func hide(owner: String, hidden: String, mode: String, on db: any SQLDatabase) async throws {
        try await db.raw("""
            INSERT INTO chat_hidden_contacts (owner_id, hidden_id, mode)
            VALUES (\(uuid: owner), \(uuid: hidden), \(bind: mode))
            ON CONFLICT DO NOTHING
            """).run()
    }

    static func unhide(owner: String, hidden: String, mode: String, on db: any SQLDatabase) async throws {
        try await db.raw("""
            DELETE FROM chat_hidden_contacts
            WHERE owner_id = \(uuid: owner) AND hidden_id = \(uuid: hidden) AND mode = \(bind: mode)
            """).run()
    }
}

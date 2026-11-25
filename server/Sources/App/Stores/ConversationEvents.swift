import Vapor
import SQLKit

/// Shared chat settings someone changed (theme, nickname), shown as centered
/// notes in the chat timeline. Migration 113.
enum ConversationEvents {
    // MARK: - Event types
    struct Event: Content {
        var id: String
        var conversation_id: String
        var kind: String
        var actor_id: String
        var actor_name: String
        @NullCoded var theme: String?
        @NullCoded var target_id: String?
        @NullCoded var target_name: String?
        @NullCoded var nickname: String?
        var created_at: Date
    }

    /// The newest note as an inbox preview (`ConversationSummary.last_event`).
    struct LastEvent: Content {
        var kind: String
        var actor_id: String
        var actor_name: String
        var theme: String?
        var target_id: String?
        var target_name: String?
        var nickname: String?
    }

    /// Notes are capped: the timeline only needs the recent ones.
    static let listLimit = 300

    // MARK: - Queries and SQL fragments
    private static func select(_ whereSQL: SQLQueryString, on db: any SQLDatabase) async throws -> [Event] {
        try await db.raw("""
            SELECT e.id::text AS id, e.conversation_id::text AS conversation_id, e.kind,
              e.actor_id::text AS actor_id,
              \(unsafeRaw: PersonaSQL.expr("display_name", modeRef: "c.mode", alias: "a")) AS actor_name,
              e.theme, e.target_id::text AS target_id,
              CASE WHEN t.id IS NULL THEN NULL
                ELSE \(unsafeRaw: PersonaSQL.expr("display_name", modeRef: "c.mode", alias: "t")) END AS target_name,
              e.nickname, e.created_at
            FROM conversation_events e
            JOIN conversations c ON c.id = e.conversation_id
            JOIN users a ON a.id = e.actor_id
            LEFT JOIN users t ON t.id = e.target_id
            \(whereSQL)
            """).all(decoding: Event.self)
    }

    /// SQL: notes in conversation `c` that count as unread for `me` (someone
    /// else's, after `readRef`, and not a group nickname, which only its
    /// setter sees). `me` must already be a quoted uuid literal.
    static func unreadSQL(me: String, readRef: String, clearedRef: String? = nil) -> String {
        """
        (SELECT COUNT(*)::int FROM conversation_events e
          WHERE e.conversation_id = c.id AND e.actor_id <> \(me)
            AND NOT (c.is_group AND e.kind = 'nickname')
            AND (\(readRef) IS NULL OR e.created_at > \(readRef))
            \(clearedRef.map { "AND e.created_at > COALESCE(\($0), '-infinity'::timestamptz)" } ?? ""))
        """
    }

    /// SQL: the newest note `me` can see in conversation `c`, shaped like the
    /// inbox's last-message row (`message_type` 'event', the note in `event`),
    /// so a theme or nickname change can be a chat's preview.
    static func latestAsMessageSQL(me: String, clearedRef: String) -> String {
        let actor = PersonaSQL.expr("display_name", modeRef: "c.mode", alias: "ea")
        let target = PersonaSQL.expr("display_name", modeRef: "c.mode", alias: "et")
        return """
        SELECT NULL::text AS content, 'event'::varchar AS message_type, e.actor_id AS sender_id, e.created_at,
          NULL::jsonb AS media_items,
          jsonb_build_object('kind', e.kind, 'actor_id', e.actor_id::text, 'actor_name', \(actor),
            'theme', e.theme, 'target_id', e.target_id::text,
            'target_name', CASE WHEN et.id IS NULL THEN NULL ELSE \(target) END, 'nickname', e.nickname) AS event
        FROM conversation_events e
        JOIN users ea ON ea.id = e.actor_id
        LEFT JOIN users et ON et.id = e.target_id
        WHERE e.conversation_id = c.id AND e.created_at > COALESCE(\(clearedRef), '-infinity'::timestamptz)
          AND NOT (c.is_group AND e.kind = 'nickname' AND e.actor_id <> \(me))
        ORDER BY e.created_at DESC LIMIT 1
        """
    }

    // MARK: - Recording and listing
    static func record(conversationID: String, actorID: String, kind: String, theme: String? = nil,
                       targetID: String? = nil, nickname: String? = nil, on db: any SQLDatabase) async throws -> Event? {
        struct R: Decodable { let id: String }
        guard let row = try await db.raw("""
            INSERT INTO conversation_events (conversation_id, actor_id, kind, theme, target_id, nickname)
            VALUES (\(uuid: conversationID), \(uuid: actorID), \(bind: kind), \(bind: theme),
                    \(bind: targetID.flatMap(UUID.init(uuidString:))), \(bind: nickname))
            RETURNING id::text AS id
            """).first(decoding: R.self) else { return nil }
        return try await select("WHERE e.id = \(uuid: row.id)", on: db).first
    }

    /// The chat's notes for `viewerID`, oldest first. A group nickname is the
    /// setter's own name for someone (conversation_nicknames is per setter),
    /// so only they see that note; a 1:1 nickname and the theme are shared.
    static func list(conversationID: String, viewerID: String, on db: any SQLDatabase) async throws -> [Event] {
        try await select("""
            WHERE e.id IN (SELECT id FROM conversation_events WHERE conversation_id = \(uuid: conversationID)
                           ORDER BY created_at DESC LIMIT \(unsafeRaw: String(listLimit)))
              AND NOT (c.is_group AND e.kind = 'nickname' AND e.actor_id <> \(uuid: viewerID))
            ORDER BY e.created_at
            """, on: db)
    }
}

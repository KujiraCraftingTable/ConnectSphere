import Vapor
import SQLKit

extension ChatStore {
    /// `listConversations` — the forked UNION-ALL (1:1 branch + group branch).
    struct ConversationSummary: Content {
        var id: String
        var mode: String
        var is_group: Bool
        @NullCoded var theme: String?
        var updated_at: Date
        @NullCoded var other_user_id: String?
        @NullCoded var other_user_username: String?
        @NullCoded var other_user_name: String?
        @NullCoded var other_user_avatar_color: String?
        @NullCoded var other_user_avatar_url: String?
        @NullCoded var other_user_job_title: String?
        @NullCoded var other_user_nickname: String?
        @NullCoded var name: String?
        @NullCoded var avatar_url: String?
        @NullCoded var avatar_color: String?
        @NullCoded var member_count: Int?
        @NullCoded var muted_until: Date?
        @NullCoded var last_message_content: String?
        @NullCoded var last_message_type: String?
        @NullCoded var last_message_sender_id: String?
        @NullCoded var last_message_at: Date?
        var unread_count: Int
    }

    static func listConversations(_ userID: String, mode: String, on db: any SQLDatabase) async throws -> [ConversationSummary] {
        let dn = PersonaSQL.expr("display_name", modeRef: "c.mode")
        let av = PersonaSQL.expr("avatar_url", modeRef: "c.mode")
        return try await db.raw("""
            (
              SELECT c.id::text AS id, c.mode, c.is_group, c.theme, c.updated_at,
                u.id::text AS other_user_id, u.username AS other_user_username,
                \(unsafeRaw: dn) AS other_user_name, u.avatar_color AS other_user_avatar_color,
                \(unsafeRaw: av) AS other_user_avatar_url, u.job_title AS other_user_job_title,
                other_cp.nickname AS other_user_nickname,
                NULL::text AS name, NULL::text AS avatar_url, NULL::text AS avatar_color, NULL::int AS member_count,
                my_cp.muted_until AS muted_until,
                lm.content AS last_message_content, lm.message_type AS last_message_type,
                lm.sender_id::text AS last_message_sender_id, lm.created_at AS last_message_at,
                (SELECT COUNT(*)::INT FROM messages m WHERE m.conversation_id = c.id AND m.sender_id != \(uuid: userID)
                  AND (my_cp.last_read_at IS NULL OR m.created_at > my_cp.last_read_at)
                  AND m.created_at > COALESCE(my_cp.cleared_at, '-infinity'::timestamptz)) AS unread_count
              FROM conversations c
              JOIN conversation_participants my_cp ON my_cp.conversation_id = c.id AND my_cp.user_id = \(uuid: userID)
              JOIN conversation_participants other_cp ON other_cp.conversation_id = c.id AND other_cp.user_id != \(uuid: userID)
              JOIN users u ON u.id = other_cp.user_id
              LEFT JOIN LATERAL (
                SELECT CASE WHEN deleted_at IS NULL THEN content ELSE NULL END AS content, message_type, sender_id, created_at
                FROM messages WHERE conversation_id = c.id AND created_at > COALESCE(my_cp.cleared_at, '-infinity'::timestamptz)
                ORDER BY created_at DESC LIMIT 1
              ) lm ON true
              WHERE c.mode = \(bind: mode) AND c.is_group = FALSE
            )
            UNION ALL
            (
              SELECT c.id::text AS id, c.mode, c.is_group, c.theme, c.updated_at,
                NULL::text AS other_user_id, NULL::text AS other_user_username, NULL::text AS other_user_name,
                NULL::text AS other_user_avatar_color, NULL::text AS other_user_avatar_url, NULL::text AS other_user_job_title,
                NULL::text AS other_user_nickname,
                c.name AS name, c.avatar_url AS avatar_url, c.avatar_color AS avatar_color,
                (SELECT COUNT(*)::INT FROM conversation_participants cp2 WHERE cp2.conversation_id = c.id) AS member_count,
                my_cp.muted_until AS muted_until,
                lm.content AS last_message_content, lm.message_type AS last_message_type,
                lm.sender_id::text AS last_message_sender_id, lm.created_at AS last_message_at,
                (SELECT COUNT(*)::INT FROM messages m WHERE m.conversation_id = c.id AND m.sender_id != \(uuid: userID)
                  AND (my_cp.last_read_at IS NULL OR m.created_at > my_cp.last_read_at)
                  AND m.created_at > COALESCE(my_cp.cleared_at, '-infinity'::timestamptz)) AS unread_count
              FROM conversations c
              JOIN conversation_participants my_cp ON my_cp.conversation_id = c.id AND my_cp.user_id = \(uuid: userID)
              LEFT JOIN LATERAL (
                SELECT CASE WHEN deleted_at IS NULL THEN content ELSE NULL END AS content, message_type, sender_id, created_at
                FROM messages WHERE conversation_id = c.id AND created_at > COALESCE(my_cp.cleared_at, '-infinity'::timestamptz)
                ORDER BY created_at DESC LIMIT 1
              ) lm ON true
              WHERE c.mode = \(bind: mode) AND c.is_group = TRUE
            )
            ORDER BY updated_at DESC
            """).all(decoding: ConversationSummary.self)
    }

    // MARK: settings

    struct Settings1to1: Content {
        @NullCoded var theme: String?
        @NullCoded var muted_until: Date?
        var other_user_id: String
        @NullCoded var other_user_username: String?
        var other_user_name: String
        @NullCoded var other_user_avatar_color: String?
        @NullCoded var other_user_job_title: String?
        @NullCoded var other_user_nickname: String?
    }
    static func settings1to1(_ conversationID: String, userID: String, on db: any SQLDatabase) async throws -> Settings1to1? {
        try await db.raw("""
            SELECT c.theme, my.muted_until,
              u.id::text AS other_user_id, u.username AS other_user_username,
              \(unsafeRaw: PersonaSQL.expr("display_name", modeRef: "c.mode")) AS other_user_name,
              u.avatar_color AS other_user_avatar_color, u.job_title AS other_user_job_title,
              other.nickname AS other_user_nickname
            FROM conversations c
            JOIN conversation_participants my ON my.conversation_id = c.id AND my.user_id = \(uuid: userID)
            JOIN conversation_participants other ON other.conversation_id = c.id AND other.user_id != \(uuid: userID)
            JOIN users u ON u.id = other.user_id
            WHERE c.id = \(uuid: conversationID)
            """).first(decoding: Settings1to1.self)
    }

    struct GroupSettings: Content {
        var id: String
        @NullCoded var name: String?
        @NullCoded var avatar_url: String?
        @NullCoded var avatar_color: String?
        @NullCoded var theme: String?
        @NullCoded var muted_until: Date?
        var created_by: String
        var members: [GroupMember]
        struct GroupMember: Content {
            var id: String; var username: String; var display_name: String
            @NullCoded var avatar_color: String?; @NullCoded var avatar_url: String?
            var role: String; var joined_at: Date
        }
    }
    static func groupSettings(_ conversationID: String, userID: String, on db: any SQLDatabase) async throws -> GroupSettings? {
        struct Conv: Decodable {
            let id: String; let theme: String?; let name: String?; let avatar_url: String?
            let avatar_color: String?; let created_by: String
        }
        guard let conv = try await db.raw("""
            SELECT id::text AS id, theme, name, avatar_url, avatar_color, created_by::text AS created_by
            FROM conversations WHERE id = \(uuid: conversationID) AND is_group = TRUE
            """).first(decoding: Conv.self) else { return nil }
        struct M: Decodable {
            let muted_until: Date?
        }
        let mute = try await db.raw("SELECT muted_until FROM conversation_participants WHERE conversation_id = \(uuid: conversationID) AND user_id = \(uuid: userID)")
            .first(decoding: M.self)?.muted_until
        let members = try await db.raw("""
            SELECT u.id::text AS id, u.username,
              \(unsafeRaw: PersonaSQL.expr("display_name", modeRef: "c.mode")) AS display_name,
              u.avatar_color, \(unsafeRaw: PersonaSQL.expr("avatar_url", modeRef: "c.mode")) AS avatar_url,
              cp.role, cp.joined_at
            FROM conversation_participants cp
            JOIN conversations c ON c.id = cp.conversation_id
            JOIN users u ON u.id = cp.user_id
            WHERE cp.conversation_id = \(uuid: conversationID)
            ORDER BY CASE cp.role WHEN 'owner' THEN 0 ELSE 1 END, cp.joined_at ASC
            """).all(decoding: GroupSettings.GroupMember.self)
        return GroupSettings(id: conv.id, name: conv.name, avatar_url: conv.avatar_url, avatar_color: conv.avatar_color,
                             theme: conv.theme, muted_until: mute, created_by: conv.created_by, members: members)
    }
}

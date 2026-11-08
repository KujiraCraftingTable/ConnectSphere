import Vapor
import SQLKit

extension ChatStore {
    /// `listConversations`, the forked UNION-ALL (1:1 branch + group branch).
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
        /// The other person is the official account (shows its seal).
        var other_user_is_official: Bool
        @NullCoded var name: String?
        @NullCoded var avatar_url: String?
        @NullCoded var avatar_color: String?
        @NullCoded var member_count: Int?
        @NullCoded var muted_until: Date?
        @NullCoded var pinned_at: Date?
        @NullCoded var archived_at: Date?
        /// "waiting" (someone who isn't your friend wrote to you), "sent" (you
        /// wrote to someone who isn't your friend), or null.
        @NullCoded var request_state: String?
        /// Messages you can still send before they accept ("sent" only).
        @NullCoded var requests_left: Int?
        @NullCoded var last_message_content: String?
        @NullCoded var last_message_type: String?
        /// Photo count when the last message is an album ("📷 4 photos").
        @NullCoded var last_message_media_count: Int?
        @NullCoded var last_message_sender_id: String?
        @NullCoded var last_message_at: Date?
        var unread_count: Int
    }

    static func listConversations(_ userID: String, mode: String, on db: any SQLDatabase) async throws -> [ConversationSummary] {
        let dn = PersonaSQL.expr("display_name", modeRef: "c.mode")
        let av = PersonaSQL.expr("avatar_url", modeRef: "c.mode")
        let pending = MessageRequests.pendingSQL(me: MessageRequests.quoted(userID), other: "u.id")
        return try await db.raw("""
            (
              SELECT c.id::text AS id, c.mode, c.is_group, c.theme, c.updated_at,
                u.id::text AS other_user_id, u.username AS other_user_username,
                \(unsafeRaw: dn) AS other_user_name, u.avatar_color AS other_user_avatar_color,
                \(unsafeRaw: av) AS other_user_avatar_url, u.job_title AS other_user_job_title,
                other_cp.nickname AS other_user_nickname, COALESCE(u.app_role = 'admin', false) AS other_user_is_official,
                NULL::text AS name, NULL::text AS avatar_url, NULL::text AS avatar_color, NULL::int AS member_count,
                my_cp.muted_until AS muted_until, my_cp.pinned_at, my_cp.archived_at,
                CASE WHEN \(unsafeRaw: pending) THEN
                  CASE WHEN c.request_from = \(uuid: userID) THEN (CASE WHEN u.app_role = 'admin' THEN NULL ELSE 'sent' END)
                    -- Messages to the official account go straight to its inbox.
                    WHEN EXISTS (SELECT 1 FROM users me WHERE me.id = \(uuid: userID) AND me.app_role = 'admin') THEN NULL
                    ELSE 'waiting' END END AS request_state,
                CASE WHEN \(unsafeRaw: pending) AND c.request_from = \(uuid: userID) AND u.app_role <> 'admin' THEN
                  GREATEST(0, \(unsafeRaw: String(MessageRequests.limit)) - (SELECT COUNT(*)::int FROM messages mm
                    WHERE mm.conversation_id = c.id AND mm.sender_id = \(uuid: userID))) END AS requests_left,
                lm.content AS last_message_content, lm.message_type AS last_message_type,
                jsonb_array_length(lm.media_items) AS last_message_media_count,
                lm.sender_id::text AS last_message_sender_id, lm.created_at AS last_message_at,
                (SELECT COUNT(*)::INT FROM messages m WHERE m.conversation_id = c.id AND m.sender_id != \(uuid: userID)
                  AND (my_cp.last_read_at IS NULL OR m.created_at > my_cp.last_read_at)
                  AND m.created_at > COALESCE(my_cp.cleared_at, '-infinity'::timestamptz)) AS unread_count
              FROM conversations c
              JOIN conversation_participants my_cp ON my_cp.conversation_id = c.id AND my_cp.user_id = \(uuid: userID)
              JOIN conversation_participants other_cp ON other_cp.conversation_id = c.id AND other_cp.user_id != \(uuid: userID)
              JOIN users u ON u.id = other_cp.user_id
              LEFT JOIN LATERAL (
                SELECT CASE WHEN deleted_at IS NULL THEN content ELSE NULL END AS content, message_type, sender_id, created_at,
                  CASE WHEN deleted_at IS NULL THEN media_items ELSE NULL END AS media_items
                FROM messages WHERE conversation_id = c.id AND created_at > COALESCE(my_cp.cleared_at, '-infinity'::timestamptz)
                ORDER BY created_at DESC LIMIT 1
              ) lm ON true
              WHERE c.mode = \(bind: mode) AND c.is_group = FALSE
                -- "Delete" (clear history) takes a chat off my list until a new message arrives.
                AND (my_cp.cleared_at IS NULL OR lm.created_at IS NOT NULL)
                -- A request with nothing in it yet isn't shown to its recipient.
                AND NOT (\(unsafeRaw: pending) AND c.request_from <> \(uuid: userID) AND lm.created_at IS NULL)
            )
            UNION ALL
            (
              SELECT c.id::text AS id, c.mode, c.is_group, c.theme, c.updated_at,
                NULL::text AS other_user_id, NULL::text AS other_user_username, NULL::text AS other_user_name,
                NULL::text AS other_user_avatar_color, NULL::text AS other_user_avatar_url, NULL::text AS other_user_job_title,
                NULL::text AS other_user_nickname, false AS other_user_is_official,
                c.name AS name, c.avatar_url AS avatar_url, c.avatar_color AS avatar_color,
                (SELECT COUNT(*)::INT FROM conversation_participants cp2 WHERE cp2.conversation_id = c.id) AS member_count,
                my_cp.muted_until AS muted_until, my_cp.pinned_at, my_cp.archived_at,
                NULL::text AS request_state, NULL::int AS requests_left,
                lm.content AS last_message_content, lm.message_type AS last_message_type,
                jsonb_array_length(lm.media_items) AS last_message_media_count,
                lm.sender_id::text AS last_message_sender_id, lm.created_at AS last_message_at,
                (SELECT COUNT(*)::INT FROM messages m WHERE m.conversation_id = c.id AND m.sender_id != \(uuid: userID)
                  AND (my_cp.last_read_at IS NULL OR m.created_at > my_cp.last_read_at)
                  AND m.created_at > COALESCE(my_cp.cleared_at, '-infinity'::timestamptz)) AS unread_count
              FROM conversations c
              JOIN conversation_participants my_cp ON my_cp.conversation_id = c.id AND my_cp.user_id = \(uuid: userID)
              LEFT JOIN LATERAL (
                SELECT CASE WHEN deleted_at IS NULL THEN content ELSE NULL END AS content, message_type, sender_id, created_at,
                  CASE WHEN deleted_at IS NULL THEN media_items ELSE NULL END AS media_items
                FROM messages WHERE conversation_id = c.id AND created_at > COALESCE(my_cp.cleared_at, '-infinity'::timestamptz)
                ORDER BY created_at DESC LIMIT 1
              ) lm ON true
              WHERE c.mode = \(bind: mode) AND c.is_group = TRUE
                -- "Delete" (clear history) takes a chat off my list until a new message arrives.
                AND (my_cp.cleared_at IS NULL OR lm.created_at IS NOT NULL)
            )
            ORDER BY pinned_at DESC NULLS LAST, updated_at DESC
            """).all(decoding: ConversationSummary.self)
    }

    // MARK: pin / archive (each participant's own inbox)

    static func setPinned(_ conversationID: String, userID: String, pinned: Bool, on db: any SQLDatabase) async throws {
        try await db.raw("""
            UPDATE conversation_participants SET pinned_at = CASE WHEN \(bind: pinned) THEN NOW() ELSE NULL END
            WHERE conversation_id = \(uuid: conversationID) AND user_id = \(uuid: userID)
            """).run()
    }

    /// Archiving also unpins: a pinned chat hidden in the archive would be a contradiction.
    static func setArchived(_ conversationID: String, userID: String, archived: Bool, on db: any SQLDatabase) async throws {
        try await db.raw("""
            UPDATE conversation_participants
            SET archived_at = CASE WHEN \(bind: archived) THEN NOW() ELSE NULL END,
                pinned_at = CASE WHEN \(bind: archived) THEN NULL ELSE pinned_at END
            WHERE conversation_id = \(uuid: conversationID) AND user_id = \(uuid: userID)
            """).run()
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
        /// Same meaning as in the conversation list: "waiting", "sent" or null.
        @NullCoded var request_state: String?
        @NullCoded var requests_left: Int?
        /// The official account is on either side: messages here can't be unsent.
        var with_official: Bool
    }
    static func settings1to1(_ conversationID: String, userID: String, on db: any SQLDatabase) async throws -> Settings1to1? {
        let pending = MessageRequests.pendingSQL(me: MessageRequests.quoted(userID), other: "u.id")
        return try await db.raw("""
            SELECT c.theme, my.muted_until,
              u.id::text AS other_user_id, u.username AS other_user_username,
              \(unsafeRaw: PersonaSQL.expr("display_name", modeRef: "c.mode")) AS other_user_name,
              u.avatar_color AS other_user_avatar_color, u.job_title AS other_user_job_title,
              other.nickname AS other_user_nickname,
              CASE WHEN \(unsafeRaw: pending) THEN
                CASE WHEN c.request_from = \(uuid: userID) THEN (CASE WHEN u.app_role = 'admin' THEN NULL ELSE 'sent' END)
                    -- Messages to the official account go straight to its inbox.
                    WHEN EXISTS (SELECT 1 FROM users me WHERE me.id = \(uuid: userID) AND me.app_role = 'admin') THEN NULL
                    ELSE 'waiting' END END AS request_state,
              CASE WHEN \(unsafeRaw: pending) AND c.request_from = \(uuid: userID) AND u.app_role <> 'admin' THEN
                GREATEST(0, \(unsafeRaw: String(MessageRequests.limit)) - (SELECT COUNT(*)::int FROM messages mm
                  WHERE mm.conversation_id = c.id AND mm.sender_id = \(uuid: userID))) END AS requests_left,
              (u.app_role = 'admin' OR EXISTS (SELECT 1 FROM users me WHERE me.id = \(uuid: userID) AND me.app_role = 'admin')) AS with_official
            FROM conversations c
            JOIN conversation_participants my ON my.conversation_id = c.id AND my.user_id = \(uuid: userID)
            JOIN conversation_participants other ON other.conversation_id = c.id AND other.user_id != \(uuid: userID)
            JOIN users u ON u.id = other.user_id
            WHERE c.id = \(uuid: conversationID)
            """).first(decoding: Settings1to1.self)
    }

    /// Mirrors Node `getGroupSettings` exactly: `{ id, theme, name, avatar_url,
    /// avatar_color, created_by, members[] }`. No mute (that's per-user, read
    /// via the 1:1/settings path), members ordered purely by `joined_at ASC`.
    struct GroupSettings: Content {
        var id: String
        @NullCoded var theme: String?
        @NullCoded var name: String?
        @NullCoded var avatar_url: String?
        @NullCoded var avatar_color: String?
        var created_by: String
        var members: [GroupMember]
        struct GroupMember: Content {
            var id: String; var username: String; var display_name: String
            @NullCoded var avatar_color: String?; @NullCoded var avatar_url: String?
            var role: String; var joined_at: Date
        }
    }
    static func groupSettings(_ conversationID: String, on db: any SQLDatabase) async throws -> GroupSettings? {
        struct Conv: Decodable {
            let id: String; let theme: String?; let name: String?; let avatar_url: String?
            let avatar_color: String?; let created_by: String
        }
        guard let conv = try await db.raw("""
            SELECT id::text AS id, theme, name, avatar_url, avatar_color, created_by::text AS created_by
            FROM conversations WHERE id = \(uuid: conversationID) AND is_group = TRUE
            """).first(decoding: Conv.self) else { return nil }
        let members = try await db.raw("""
            SELECT u.id::text AS id, u.username,
              \(unsafeRaw: PersonaSQL.expr("display_name", modeRef: "c.mode")) AS display_name,
              u.avatar_color, \(unsafeRaw: PersonaSQL.expr("avatar_url", modeRef: "c.mode")) AS avatar_url,
              cp.role, cp.joined_at
            FROM conversation_participants cp
            JOIN conversations c ON c.id = cp.conversation_id
            JOIN users u ON u.id = cp.user_id
            WHERE cp.conversation_id = \(uuid: conversationID)
            ORDER BY cp.joined_at ASC
            """).all(decoding: GroupSettings.GroupMember.self)
        return GroupSettings(id: conv.id, theme: conv.theme, name: conv.name, avatar_url: conv.avatar_url,
                             avatar_color: conv.avatar_color, created_by: conv.created_by, members: members)
    }
}

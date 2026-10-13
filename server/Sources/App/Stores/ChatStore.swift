import Vapor
import SQLKit

/// Port of the core of `backend/src/models/messageModel.js` — conversations,
/// messages (with the `MESSAGE_EMBED_SELECT` jsonb shaping), settings, mute,
/// media, search, reactions, pins, receipts. Group management + meeting-proposal
/// mutation + the Socket.IO fan-out land in later Phase 4 slices.
enum ChatStore {
    static let reactionEmoji = ["❤️", "👍", "😂", "😮", "😢", "🔥"]
    static let maxPins = 10

    /// `MESSAGE_EMBED_SELECT`: the reply preview, reaction map, embedded meeting
    /// proposal, is_pinned, and the delivered_to / read_by receipt arrays.
    /// Selected as `::text` for the jsonb pieces (parsed in Swift with the
    /// tolerant ISO decoder). Requires the query to alias the message row `m`
    /// and join c / rm / ru / mp per the Node comment.
    static let embed: SQLQueryString = """
        (CASE WHEN rm.id IS NOT NULL THEN jsonb_build_object(
          'id', rm.id, 'sender_id', rm.sender_id,
          'sender_name', \(unsafeRaw: PersonaSQL.expr("display_name", modeRef: "c.mode", alias: "ru")),
          'message_type', rm.message_type, 'is_deleted', (rm.deleted_at IS NOT NULL),
          'content', CASE WHEN rm.deleted_at IS NOT NULL THEN NULL ELSE LEFT(COALESCE(rm.content,
            CASE rm.message_type WHEN 'image' THEN '📷 Photo' WHEN 'album' THEN '📷 Album' WHEN 'video' THEN '🎥 Video'
              WHEN 'voice' THEN '🎤 Voice message' ELSE '' END), 120) END
        ) ELSE NULL END)::text AS replied_message,
        COALESCE((SELECT jsonb_object_agg(agg.emoji, agg.user_ids) FROM (
          SELECT emoji, jsonb_agg(user_id) AS user_ids FROM message_reactions WHERE message_id = m.id GROUP BY emoji) agg
        ), '{}'::jsonb)::text AS reactions,
        (CASE WHEN mp.id IS NOT NULL THEN jsonb_build_object(
          'id', mp.id, 'title', mp.title, 'location', mp.location, 'starts_at', mp.starts_at, 'ends_at', mp.ends_at,
          'status', mp.status, 'reminder_offset', mp.reminder_offset, 'reminder_at', mp.reminder_at,
          'reminder_sent_at', mp.reminder_sent_at, 'created_at', mp.created_at, 'updated_at', mp.updated_at,
          'rsvps', COALESCE((SELECT jsonb_object_agg(agg.status, agg.user_ids) FROM (
            SELECT status, jsonb_agg(user_id) AS user_ids FROM message_meeting_rsvps WHERE proposal_id = mp.id GROUP BY status) agg
          ), '{}'::jsonb)
        ) ELSE NULL END)::text AS meeting_proposal,
        (SELECT jsonb_build_object('ends_at', cp.ends_at, 'options', COALESCE((
          SELECT jsonb_agg(jsonb_build_object('id', o.id, 'text', o.text, 'vote_count', o.vote_count,
            'voters', COALESCE((SELECT jsonb_agg(jsonb_build_object('id', vu.id,
                'display_name', \(unsafeRaw: PersonaSQL.expr("display_name", modeRef: "c.mode", alias: "vu")),
                'avatar_url', \(unsafeRaw: PersonaSQL.expr("avatar_url", modeRef: "c.mode", alias: "vu")),
                'avatar_color', vu.avatar_color) ORDER BY v.voted_at)
              FROM chat_poll_votes v JOIN users vu ON vu.id = v.user_id WHERE v.option_id = o.id), '[]'::jsonb)
          ) ORDER BY o.position) FROM chat_poll_options o WHERE o.message_id = cp.message_id), '[]'::jsonb))
         FROM chat_polls cp WHERE cp.message_id = m.id AND m.deleted_at IS NULL)::text AS poll,
        EXISTS(SELECT 1 FROM message_pins WHERE message_id = m.id) AS is_pinned,
        COALESCE((SELECT jsonb_agg(mr.user_id) FROM message_receipts mr WHERE mr.message_id = m.id AND mr.kind = 'delivered'), '[]'::jsonb)::text AS delivered_to,
        COALESCE((SELECT jsonb_agg(mr.user_id) FROM message_receipts mr WHERE mr.message_id = m.id AND mr.kind = 'read'), '[]'::jsonb)::text AS read_by
        """

    struct MessageRow: Decodable {
        var id: String; var conversation_id: String; var sender_id: String
        var content: String?; var message_type: String; var media_url: String?
        var media_items: String?
        var voice_duration_seconds: Int?; var voice_waveform: [Double]?
        var created_at: Date; var reply_to_message_id: String?; var is_deleted: Bool
        var replied_message: String?; var reactions: String; var meeting_proposal: String?
        var poll: String?
        var is_pinned: Bool; var delivered_to: String; var read_by: String
    }

    static func mapMessage(_ r: MessageRow) throws -> MessageObject {
        let dec = JSONCoding.makeDecoder()
        func obj<T: Decodable>(_ s: String?, _ t: T.Type) -> T? {
            guard let s, s != "null" else { return nil }
            return try? dec.decode(T.self, from: Data(s.utf8))
        }
        return MessageObject(
            id: r.id, conversation_id: r.conversation_id, sender_id: r.sender_id, content: r.content,
            message_type: r.message_type, media_url: r.media_url,
            media_items: obj(r.media_items, [MessageObject.MediaItem].self),
            voice_duration_seconds: r.voice_duration_seconds, voice_waveform: r.voice_waveform,
            created_at: r.created_at, reply_to_message_id: r.reply_to_message_id, is_deleted: r.is_deleted,
            replied_message: obj(r.replied_message, MessageObject.RepliedMessage.self),
            reactions: obj(r.reactions, [String: [String]].self) ?? [:],
            meeting_proposal: obj(r.meeting_proposal, MessageObject.MeetingProposal.self),
            is_pinned: r.is_pinned,
            delivered_to: obj(r.delivered_to, [String].self) ?? [],
            read_by: obj(r.read_by, [String].self) ?? [],
            poll: obj(r.poll, MessageObject.Poll.self))
    }

    static let msgSelect: SQLQueryString = """
        SELECT m.id::text AS id, m.conversation_id::text AS conversation_id, m.sender_id::text AS sender_id,
          CASE WHEN m.deleted_at IS NULL THEN m.content ELSE NULL END AS content, m.message_type,
          CASE WHEN m.deleted_at IS NULL THEN m.media_url ELSE NULL END AS media_url,
          CASE WHEN m.deleted_at IS NULL THEN m.media_items::text ELSE NULL END AS media_items,
          CASE WHEN m.deleted_at IS NULL THEN m.voice_duration_seconds ELSE NULL END AS voice_duration_seconds,
          CASE WHEN m.deleted_at IS NULL THEN m.voice_waveform ELSE NULL END AS voice_waveform,
          m.created_at, m.reply_to_message_id::text AS reply_to_message_id, (m.deleted_at IS NOT NULL) AS is_deleted,
        """

    static let msgFrom: SQLQueryString = """
        FROM messages m
        JOIN conversations c ON c.id = m.conversation_id
        LEFT JOIN messages rm ON rm.id = m.reply_to_message_id
        LEFT JOIN users ru ON ru.id = rm.sender_id
        LEFT JOIN message_meeting_proposals mp ON mp.message_id = m.id
        """

    // MARK: conversations

    static func isParticipant(_ conversationID: String, _ userID: String, on db: any SQLDatabase) async throws -> Bool {
        struct One: Decodable { let one: Int }
        return try await db.raw("SELECT 1 AS one FROM conversation_participants WHERE conversation_id = \(uuid: conversationID) AND user_id = \(uuid: userID)")
            .first(decoding: One.self) != nil
    }
    static func participants(_ conversationID: String, on db: any SQLDatabase) async throws -> [String] {
        struct R: Decodable { let user_id: String }
        return try await db.raw("SELECT user_id::text AS user_id FROM conversation_participants WHERE conversation_id = \(uuid: conversationID)")
            .all(decoding: R.self).map(\.user_id)
    }
    struct ConvBasic: Decodable {
        let id: String; let mode: String; let theme: String?; let is_group: Bool
        let name: String?; let avatar_url: String?; let avatar_color: String?; let created_by: String?
    }
    static func conversationByID(_ id: String, on db: any SQLDatabase) async throws -> ConvBasic? {
        try await db.raw("""
            SELECT id::text AS id, mode, theme, is_group, name, avatar_url, avatar_color, created_by::text AS created_by
            FROM conversations WHERE id = \(uuid: id)
            """).first(decoding: ConvBasic.self)
    }

    static func findConversation(_ a: String, _ b: String, mode: String, on db: any SQLDatabase) async throws -> String? {
        struct R: Decodable { let id: String }
        // Folded review fix: only a real 1:1 (is_group = FALSE), LIMIT 1.
        return try await db.raw("""
            SELECT c.id::text AS id FROM conversations c
            JOIN conversation_participants p1 ON p1.conversation_id = c.id AND p1.user_id = \(uuid: a)
            JOIN conversation_participants p2 ON p2.conversation_id = c.id AND p2.user_id = \(uuid: b)
            WHERE c.mode = \(bind: mode) AND c.is_group = FALSE LIMIT 1
            """).first(decoding: R.self)?.id
    }
    /// `requestFrom`: the starter when the two aren't friends — the chat then
    /// waits for the other person to accept (migration 040).
    static func createConversation(_ a: String, _ b: String, mode: String, requestFrom: String? = nil,
                                   on db: AppDatabase) async throws -> String {
        var id = ""
        try await db.tx { t in
            struct R: Decodable { let id: String }
            // Folded review fix: single INSERT ... ON CONFLICT so a double-tap
            // can't make two threads / orphan participants.
            id = try await t.raw("""
                INSERT INTO conversations (mode, request_from) VALUES (\(bind: mode), \(uuid: requestFrom))
                RETURNING id::text AS id
                """).first(decoding: R.self)!.id
            try await t.raw("INSERT INTO conversation_participants (conversation_id, user_id) VALUES (\(uuid: id), \(uuid: a)), (\(uuid: id), \(uuid: b))").run()
        }
        return id
    }

    // MARK: messages

    static func listMessages(_ conversationID: String, userID: String, limit: Int, before: String?, on db: any SQLDatabase) async throws -> [MessageObject] {
        var q = msgSelect + embed + " " + msgFrom
        q = q + " WHERE m.conversation_id = \(uuid: conversationID) AND m.created_at > COALESCE((SELECT cleared_at FROM conversation_participants WHERE conversation_id = \(uuid: conversationID) AND user_id = \(uuid: userID)), '-infinity'::timestamptz)"
        if let before { q = q + " AND m.created_at < \(bind: before)::timestamptz" }
        q = q + " ORDER BY m.created_at DESC LIMIT \(bind: limit)"
        return try await db.raw(q).all(decoding: MessageRow.self).map(mapMessage)
    }

    static func messageByID(_ id: String, on db: any SQLDatabase) async throws -> MessageObject? {
        let q = msgSelect + embed + " " + msgFrom + " WHERE m.id = \(uuid: id)"
        guard let row = try await db.raw(q).first(decoding: MessageRow.self) else { return nil }
        return try mapMessage(row)
    }

    struct BasicMsg: Decodable { let id: String; let conversation_id: String; let sender_id: String }
    static func messageBasic(_ id: String, on db: any SQLDatabase) async throws -> BasicMsg? {
        try await db.raw("SELECT id::text AS id, conversation_id::text AS conversation_id, sender_id::text AS sender_id FROM messages WHERE id = \(uuid: id)")
            .first(decoding: BasicMsg.self)
    }

    static func insertMessage(_ conversationID: String, senderID: String, content: String?, messageType: String,
                              mediaUrl: String?, mediaItems: [MessageObject.MediaItem]? = nil,
                              replyToMessageID: String?, voiceDuration: Int?, voiceWaveform: [Double]?,
                              on db: any SQLDatabase) async throws -> String {
        struct R: Decodable { let id: String }
        let itemsJSON = try mediaItems.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }
        let id = try await db.raw("""
            INSERT INTO messages (conversation_id, sender_id, content, message_type, media_url, media_items, reply_to_message_id, voice_duration_seconds, voice_waveform)
            VALUES (\(uuid: conversationID), \(uuid: senderID), \(bind: content), \(bind: messageType), \(bind: mediaUrl),
                    \(bind: itemsJSON)::jsonb, \(uuid: replyToMessageID), \(bind: voiceDuration), \(bind: voiceWaveform))
            RETURNING id::text AS id
            """).first(decoding: R.self)!.id
        try await db.raw("UPDATE conversations SET updated_at = NOW() WHERE id = \(uuid: conversationID)").run()
        // A new message brings an archived chat back for everyone in it.
        try await db.raw("""
            UPDATE conversation_participants SET archived_at = NULL
            WHERE conversation_id = \(uuid: conversationID) AND archived_at IS NOT NULL
            """).run()
        return id
    }

    static func recall(_ messageID: String, conversationID: String, senderID: String, on db: any SQLDatabase) async throws -> Bool {
        struct R: Decodable { let id: String }
        return try await db.raw("""
            UPDATE messages SET deleted_at = NOW()
            WHERE id = \(uuid: messageID) AND conversation_id = \(uuid: conversationID) AND sender_id = \(uuid: senderID) AND deleted_at IS NULL
            RETURNING id
            """).first(decoding: R.self) != nil
    }

    /// Returns the ids that gained a NEW 'read' receipt (for the caller's emit).
    static func markRead(_ conversationID: String, userID: String, on db: any SQLDatabase) async throws -> [String] {
        struct R: Decodable { let message_id: String }
        let ids = try await db.raw("""
            WITH ins AS (
              INSERT INTO message_receipts (message_id, user_id, kind)
              SELECT m.id, \(uuid: userID), k.kind FROM messages m
              CROSS JOIN (VALUES ('delivered'), ('read')) AS k(kind)
              WHERE m.conversation_id = \(uuid: conversationID) AND m.sender_id != \(uuid: userID)
              ON CONFLICT (message_id, user_id, kind) DO NOTHING RETURNING message_id, kind
            ) SELECT DISTINCT message_id::text AS message_id FROM ins WHERE kind = 'read'
            """).all(decoding: R.self).map(\.message_id)
        // Folded review fix: also set last_read_at so the global badge can't
        // drift from the per-conversation unread.
        try await db.raw("UPDATE conversation_participants SET last_read_at = NOW() WHERE conversation_id = \(uuid: conversationID) AND user_id = \(uuid: userID)").run()
        return ids
    }

    struct DeliveredRow: Content { let id: String; let sender_id: String }
    static func markConversationDelivered(_ conversationID: String, userID: String, on db: any SQLDatabase) async throws -> [DeliveredRow] {
        try await db.raw("""
            WITH ins AS (
              INSERT INTO message_receipts (message_id, user_id, kind)
              SELECT m.id, \(uuid: userID), 'delivered' FROM messages m
              WHERE m.conversation_id = \(uuid: conversationID) AND m.sender_id != \(uuid: userID)
              ON CONFLICT (message_id, user_id, kind) DO NOTHING RETURNING message_id
            )
            SELECT m.id::text AS id, m.sender_id::text AS sender_id FROM ins JOIN messages m ON m.id = ins.message_id
            """).all(decoding: DeliveredRow.self)
    }

    static func totalUnread(_ userID: String, mode: String, on db: any SQLDatabase) async throws -> Int {
        struct N: Decodable { let total: Int }
        return try await db.raw("""
            SELECT COALESCE(SUM((SELECT COUNT(*) FROM messages m
              WHERE m.conversation_id = c.id AND m.sender_id != \(uuid: userID)
                AND (cp.last_read_at IS NULL OR m.created_at > cp.last_read_at))), 0)::int AS total
            FROM conversations c
            JOIN conversation_participants cp ON cp.conversation_id = c.id AND cp.user_id = \(uuid: userID)
            WHERE c.mode = \(bind: mode)
              -- Waiting requests don't count until accepted.
              AND NOT (c.request_from IS NOT NULL AND c.request_from <> \(uuid: userID) AND c.request_accepted_at IS NULL
                       AND NOT \(unsafeRaw: MessageRequests.connectedSQL(
                           "\(MessageRequests.quoted(userID))",
                           "(SELECT o.user_id FROM conversation_participants o WHERE o.conversation_id = c.id AND o.user_id <> cp.user_id LIMIT 1)",
                           mode: "c.mode")))
            """).first(decoding: N.self)?.total ?? 0
    }

    static func clearConversation(_ conversationID: String, userID: String, on db: any SQLDatabase) async throws {
        try await db.raw("UPDATE conversation_participants SET cleared_at = NOW() WHERE conversation_id = \(uuid: conversationID) AND user_id = \(uuid: userID)").run()
    }
    static func setMute(_ conversationID: String, userID: String, minutes: Int?, on db: any SQLDatabase) async throws -> Date? {
        struct R: Decodable { let muted_until: Date? }
        return try await db.raw("""
            UPDATE conversation_participants SET muted_until = CASE
              WHEN \(bind: minutes)::int IS NULL THEN NULL
              WHEN \(bind: minutes) < 0 THEN NOW() + INTERVAL '100 years'
              ELSE NOW() + (\(bind: minutes) || ' minutes')::interval END
            WHERE conversation_id = \(uuid: conversationID) AND user_id = \(uuid: userID)
            RETURNING muted_until
            """).first(decoding: R.self)?.muted_until ?? nil
    }

    // MARK: reactions

    static func setReaction(_ messageID: String, userID: String, emoji: String, on db: any SQLDatabase) async throws -> [String: [String]] {
        struct E: Decodable { let emoji: String }
        let existing = try await db.raw("SELECT emoji FROM message_reactions WHERE message_id = \(uuid: messageID) AND user_id = \(uuid: userID)")
            .first(decoding: E.self)
        if existing?.emoji == emoji {
            try await db.raw("DELETE FROM message_reactions WHERE message_id = \(uuid: messageID) AND user_id = \(uuid: userID)").run()
        } else {
            try await db.raw("""
                INSERT INTO message_reactions (message_id, user_id, emoji) VALUES (\(uuid: messageID), \(uuid: userID), \(bind: emoji))
                ON CONFLICT (message_id, user_id) DO UPDATE SET emoji = EXCLUDED.emoji, created_at = NOW()
                """).run()
        }
        struct A: Decodable { let map: String }
        let m = try await db.raw("""
            SELECT COALESCE((SELECT jsonb_object_agg(agg.emoji, agg.user_ids) FROM (
              SELECT emoji, jsonb_agg(user_id) AS user_ids FROM message_reactions WHERE message_id = \(uuid: messageID) GROUP BY emoji) agg
            ), '{}'::jsonb)::text AS map
            """).first(decoding: A.self)!.map
        return (try? JSONCoding.makeDecoder().decode([String: [String]].self, from: Data(m.utf8))) ?? [:]
    }

    // MARK: media / search / pins

    struct MediaItem: Content {
        var id: String; var conversation_id: String; var sender_id: String
        var message_type: String; var media_url: String?; var created_at: Date
    }
    /// Every photo/video in the chat, newest first — an album contributes each
    /// of its photos (id `<message id>:<index>`, in album order).
    static func media(_ conversationID: String, userID: String, on db: any SQLDatabase) async throws -> [MediaItem] {
        try await db.raw("""
            WITH visible AS (
              SELECT m.* FROM messages m
              WHERE m.conversation_id = \(uuid: conversationID) AND m.deleted_at IS NULL
                AND m.message_type IN ('image', 'video', 'album')
                AND m.created_at > COALESCE((SELECT cleared_at FROM conversation_participants WHERE conversation_id = \(uuid: conversationID) AND user_id = \(uuid: userID)), '-infinity'::timestamptz)
            )
            SELECT id, conversation_id, sender_id, message_type, media_url, created_at FROM (
              SELECT v.id::text AS id, v.conversation_id::text AS conversation_id, v.sender_id::text AS sender_id,
                v.message_type, v.media_url, v.created_at, 0::bigint AS ord
              FROM visible v WHERE v.message_type IN ('image', 'video')
              UNION ALL
              SELECT v.id::text || ':' || (it.ord - 1) AS id, v.conversation_id::text, v.sender_id::text,
                it.item->>'type', it.item->>'url', v.created_at, it.ord
              FROM visible v CROSS JOIN LATERAL jsonb_array_elements(v.media_items) WITH ORDINALITY AS it(item, ord)
              WHERE v.message_type = 'album'
            ) all_media
            ORDER BY created_at DESC, ord
            """).all(decoding: MediaItem.self)
    }
    /// Node's `searchMessages` SELECT omits the two voice columns, so the search
    /// result shape has no `voice_duration_seconds` / `voice_waveform` keys.
    struct SearchMsgRow: Decodable {
        var id: String; var conversation_id: String; var sender_id: String
        var content: String?; var message_type: String; var media_url: String?
        var created_at: Date; var reply_to_message_id: String?; var is_deleted: Bool
        var replied_message: String?; var reactions: String; var meeting_proposal: String?
        var is_pinned: Bool; var delivered_to: String; var read_by: String
    }
    static func searchMessages(_ conversationID: String, userID: String, term: String, on db: any SQLDatabase) async throws -> [SearchMessageObject] {
        let escaped = UserStore.escapeLike(term)
        var q: SQLQueryString = """
            SELECT m.id::text AS id, m.conversation_id::text AS conversation_id, m.sender_id::text AS sender_id, m.content,
              m.message_type, m.media_url, m.created_at, m.reply_to_message_id::text AS reply_to_message_id,
              (m.deleted_at IS NOT NULL) AS is_deleted,
            """
        q = q + embed + " " + msgFrom
        q = q + " WHERE m.conversation_id = \(uuid: conversationID) AND m.deleted_at IS NULL AND m.message_type IN ('text', 'album')"
        q = q + " AND m.content ILIKE '%' || \(bind: escaped) || '%'"
        q = q + " AND m.created_at > COALESCE((SELECT cleared_at FROM conversation_participants WHERE conversation_id = \(uuid: conversationID) AND user_id = \(uuid: userID)), '-infinity'::timestamptz)"
        q = q + " ORDER BY m.created_at DESC LIMIT 50"
        let dec = JSONCoding.makeDecoder()
        func obj<T: Decodable>(_ s: String?, _ t: T.Type) -> T? {
            guard let s, s != "null" else { return nil }
            return try? dec.decode(T.self, from: Data(s.utf8))
        }
        return try await db.raw(q).all(decoding: SearchMsgRow.self).map { r in
            SearchMessageObject(id: r.id, conversation_id: r.conversation_id, sender_id: r.sender_id, content: r.content,
                message_type: r.message_type, media_url: r.media_url, created_at: r.created_at,
                reply_to_message_id: r.reply_to_message_id, is_deleted: r.is_deleted,
                replied_message: obj(r.replied_message, MessageObject.RepliedMessage.self),
                reactions: obj(r.reactions, [String: [String]].self) ?? [:],
                meeting_proposal: obj(r.meeting_proposal, MessageObject.MeetingProposal.self),
                is_pinned: r.is_pinned, delivered_to: obj(r.delivered_to, [String].self) ?? [],
                read_by: obj(r.read_by, [String].self) ?? [])
        }
    }

    struct PinRow: Content {
        var id: String; var message_id: String; var pinned_by: String; var pinned_at: Date
        @NullCoded var expires_at: Date?; var conversation_id: String; var message_type: String
        var is_deleted: Bool; @NullCoded var content: String?; var sender_id: String; var sender_name: String
    }
    static func listPins(_ conversationID: String, on db: any SQLDatabase) async throws -> [PinRow] {
        try await db.raw("""
            SELECT mp.id::text AS id, mp.message_id::text AS message_id, mp.pinned_by::text AS pinned_by, mp.pinned_at, mp.expires_at,
              m.conversation_id::text AS conversation_id, m.message_type, (m.deleted_at IS NOT NULL) AS is_deleted,
              CASE WHEN m.deleted_at IS NULL THEN m.content ELSE NULL END AS content, m.sender_id::text AS sender_id,
              \(unsafeRaw: PersonaSQL.expr("display_name", modeRef: "c.mode", alias: "u")) AS sender_name
            FROM message_pins mp
            JOIN messages m ON m.id = mp.message_id
            JOIN conversations c ON c.id = m.conversation_id
            JOIN users u ON u.id = m.sender_id
            WHERE mp.conversation_id = \(uuid: conversationID)
            ORDER BY mp.pinned_at DESC
            """).all(decoding: PinRow.self)
    }
    /// Node's `pinMessage` returns `RETURNING *` — the full `message_pins` row.
    struct PinInserted: Content {
        var id: String; var conversation_id: String; var message_id: String
        var pinned_by: String; var pinned_at: Date; @NullCoded var expires_at: Date?
    }
    static func pinMessage(_ conversationID: String, messageID: String, userID: String, expiresAt: String?, on db: any SQLDatabase) async throws -> PinInserted? {
        try await db.raw("""
            INSERT INTO message_pins (conversation_id, message_id, pinned_by, expires_at)
            SELECT \(uuid: conversationID), \(uuid: messageID), \(uuid: userID), \(bind: expiresAt)::timestamptz
            WHERE (SELECT COUNT(*) FROM message_pins WHERE conversation_id = \(uuid: conversationID)) < \(bind: maxPins)
            RETURNING id::text AS id, conversation_id::text AS conversation_id, message_id::text AS message_id,
                      pinned_by::text AS pinned_by, pinned_at, expires_at
            """).first(decoding: PinInserted.self)
    }
    static func unpinMessage(_ conversationID: String, messageID: String, on db: any SQLDatabase) async throws -> Bool {
        struct R: Decodable { let id: String }
        return try await db.raw("DELETE FROM message_pins WHERE conversation_id = \(uuid: conversationID) AND message_id = \(uuid: messageID) RETURNING id::text AS id")
            .first(decoding: R.self) != nil
    }
}

struct MessageObject: Content {
    var id: String
    var conversation_id: String
    var sender_id: String
    @NullCoded var content: String?
    var message_type: String
    @NullCoded var media_url: String?
    /// An album's photos in order (`message_type == "album"`); null otherwise.
    @NullCoded var media_items: [MediaItem]?
    @NullCoded var voice_duration_seconds: Int?
    @NullCoded var voice_waveform: [Double]?
    var created_at: Date
    @NullCoded var reply_to_message_id: String?
    var is_deleted: Bool
    @NullCoded var replied_message: RepliedMessage?
    var reactions: [String: [String]]
    @NullCoded var meeting_proposal: MeetingProposal?
    var is_pinned: Bool
    var delivered_to: [String]
    var read_by: [String]
    /// A group poll (`message_type == "poll"`, migration 052); null otherwise.
    @NullCoded var poll: Poll? = nil

    struct MediaItem: Content, Equatable {
        var url: String
        var type: String
    }
    struct RepliedMessage: Content {
        var id: String; var sender_id: String; var sender_name: String
        var message_type: String; var is_deleted: Bool; @NullCoded var content: String?
    }
    struct MeetingProposal: Content {
        var id: String; var title: String; @NullCoded var location: String?
        var starts_at: Date; @NullCoded var ends_at: Date?; var status: String
        var reminder_offset: String; var reminder_at: Date; @NullCoded var reminder_sent_at: Date?
        var created_at: Date; var updated_at: Date; var rsvps: [String: [String]]
    }
    /// Options in order, each with who voted for it (oldest first) — the app
    /// finds "my vote" here, so the same payload can go to every member.
    struct Poll: Content {
        @NullCoded var ends_at: Date?
        var options: [Option]
        struct Option: Content {
            var id: String; var text: String; var vote_count: Int; var voters: [Voter]
        }
        struct Voter: Content {
            var id: String; var display_name: String
            @NullCoded var avatar_url: String?; @NullCoded var avatar_color: String?
        }
    }
}

/// Message shape for search results — same as `MessageObject` minus the two
/// voice columns (Node's search query doesn't project them).
struct SearchMessageObject: Content {
    var id: String
    var conversation_id: String
    var sender_id: String
    @NullCoded var content: String?
    var message_type: String
    @NullCoded var media_url: String?
    var created_at: Date
    @NullCoded var reply_to_message_id: String?
    var is_deleted: Bool
    @NullCoded var replied_message: MessageObject.RepliedMessage?
    var reactions: [String: [String]]
    @NullCoded var meeting_proposal: MessageObject.MeetingProposal?
    var is_pinned: Bool
    var delivered_to: [String]
    var read_by: [String]
}

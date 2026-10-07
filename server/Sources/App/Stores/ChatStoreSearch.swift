import Vapor
import SQLKit

extension ChatStore {
    /// One row of `GET /messages/search` — every `ConversationSummary` field
    /// (so the client can decode the same way it decodes a normal
    /// conversation-list row) plus what matched and why.
    struct ConversationSearchHit: Content {
        var id: String
        var mode: String
        var is_group: Bool
        var theme: String?
        var updated_at: Date
        var other_user_id: String?
        var other_user_username: String?
        var other_user_name: String?
        var other_user_avatar_color: String?
        var other_user_avatar_url: String?
        var other_user_job_title: String?
        var other_user_nickname: String?
        var name: String?
        var avatar_url: String?
        var avatar_color: String?
        var member_count: Int?
        var muted_until: Date?
        var last_message_content: String?
        var last_message_type: String?
        var last_message_sender_id: String?
        var last_message_at: Date?
        var unread_count: Int
        /// "name" (conversation/participant display name matched) or
        /// "message" (a message's content matched).
        var match_type: String
        var matched_message_id: String?
        var matched_snippet: String?

        init(_ s: ConversationSummary, matchType: String, matchedMessageId: String? = nil, matchedSnippet: String? = nil) {
            id = s.id
            mode = s.mode
            is_group = s.is_group
            theme = s.theme
            updated_at = s.updated_at
            other_user_id = s.other_user_id
            other_user_username = s.other_user_username
            other_user_name = s.other_user_name
            other_user_avatar_color = s.other_user_avatar_color
            other_user_avatar_url = s.other_user_avatar_url
            other_user_job_title = s.other_user_job_title
            other_user_nickname = s.other_user_nickname
            name = s.name
            avatar_url = s.avatar_url
            avatar_color = s.avatar_color
            member_count = s.member_count
            muted_until = s.muted_until
            last_message_content = s.last_message_content
            last_message_type = s.last_message_type
            last_message_sender_id = s.last_message_sender_id
            last_message_at = s.last_message_at
            unread_count = s.unread_count
            match_type = matchType
            matched_message_id = matchedMessageId
            matched_snippet = matchedSnippet
        }
    }

    private struct ContentMatchRow: Decodable {
        var conversation_id: String
        var message_id: String
        var content: String?
        var created_at: Date
    }

    /// Cross-conversation search — content matches (message text, most recent
    /// hit per conversation) first, then any name matches not already covered.
    /// Scoped to conversations `userID` actually participates in, same as
    /// `listConversations` (which this reuses for display metadata rather
    /// than re-deriving the persona-join SQL).
    static func searchAllConversations(_ userID: String, mode: String, term: String, on db: any SQLDatabase) async throws -> [ConversationSearchHit] {
        let all = try await listConversations(userID, mode: mode, on: db)
        var byId: [String: ConversationSummary] = [:]
        for s in all { byId[s.id] = s }

        let escaped = UserStore.escapeLike(term)
        let rows = try await db.raw("""
            SELECT m.conversation_id::text AS conversation_id, m.id::text AS message_id, m.content, m.created_at
            FROM messages m
            JOIN conversations c ON c.id = m.conversation_id
            JOIN conversation_participants cp ON cp.conversation_id = c.id AND cp.user_id = \(uuid: userID)
            WHERE c.mode = \(bind: mode) AND m.deleted_at IS NULL AND m.message_type IN ('text', 'album')
              AND m.content ILIKE '%' || \(bind: escaped) || '%'
              AND m.created_at > COALESCE(cp.cleared_at, '-infinity'::timestamptz)
            ORDER BY m.created_at DESC
            LIMIT 50
            """).all(decoding: ContentMatchRow.self)

        var seen = Set<String>()
        var hits: [ConversationSearchHit] = []
        for row in rows {
            guard !seen.contains(row.conversation_id), let summary = byId[row.conversation_id] else { continue }
            seen.insert(row.conversation_id)
            hits.append(ConversationSearchHit(summary, matchType: "message", matchedMessageId: row.message_id, matchedSnippet: row.content))
        }

        let lowerTerm = term.lowercased()
        for s in all where !seen.contains(s.id) {
            let name = s.is_group ? (s.name ?? "") : (s.other_user_nickname ?? s.other_user_name ?? "")
            guard name.lowercased().contains(lowerTerm) else { continue }
            seen.insert(s.id)
            hits.append(ConversationSearchHit(s, matchType: "name"))
        }

        return Array(hits.prefix(30))
    }
}

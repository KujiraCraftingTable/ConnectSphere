import Vapor
import SQLKit

/// Message requests (migration 040): a 1-on-1 chat started by someone who
/// isn't the other person's friend waits in their "Waiting" list, and its
/// starter may send at most `limit` messages until it's accepted.
enum MessageRequests {
    static let limit = 3

    /// `'<uuid>'::uuid` for embedding a *validated* id in a SQL fragment
    /// (callers pass the authenticated user's id, never request input).
    static func quoted(_ id: String) -> String {
        guard let uuid = UUID(uuidString: id) else { return "NULL::uuid" }
        return "'\(uuid.uuidString.lowercased())'::uuid"
    }

    /// SQL: are `a` and `b` accepted friends/connections in `mode`?
    static func connectedSQL(_ a: String, _ b: String, mode: String) -> String {
        """
        EXISTS (SELECT 1 FROM connections cn WHERE cn.status = 'accepted' AND cn.mode = \(mode)
                AND ((cn.requester_id = \(a) AND cn.addressee_id = \(b))
                  OR (cn.requester_id = \(b) AND cn.addressee_id = \(a))))
        """
    }

    /// SQL (conversation alias `c`): is this chat still an unaccepted request?
    static func pendingSQL(me: String, other: String) -> String {
        "(c.request_from IS NOT NULL AND c.request_accepted_at IS NULL AND NOT \(connectedSQL(me, other, mode: "c.mode")))"
    }

    static func areConnected(_ a: String, _ b: String, mode: String, on db: any SQLDatabase) async throws -> Bool {
        struct X: Decodable { let x: Int }
        return try await db.raw("""
            SELECT 1 AS x FROM connections
            WHERE status = 'accepted' AND mode = \(bind: mode)
              AND ((requester_id = \(uuid: a) AND addressee_id = \(uuid: b))
                OR (requester_id = \(uuid: b) AND addressee_id = \(uuid: a)))
            """).first(decoding: X.self) != nil
    }

    enum Gate: Equatable {
        case open
        /// The starter has used up their messages; the reason to show.
        case limitReached
    }

    /// Checks a send before it's stored. The recipient writing back counts as
    /// accepting the request, so it's marked accepted here too.
    static func gate(conversationID: String, senderID: String, on db: any SQLDatabase) async throws -> Gate {
        struct R: Decodable {
            let request_from: String?; let accepted: Bool; let is_group: Bool; let mode: String
            let other_id: String?; let sent: Int
        }
        guard let r = try await db.raw("""
            SELECT c.request_from::text AS request_from, (c.request_accepted_at IS NOT NULL) AS accepted,
              c.is_group, c.mode,
              (SELECT o.user_id::text FROM conversation_participants o
                WHERE o.conversation_id = c.id AND o.user_id <> \(uuid: senderID) LIMIT 1) AS other_id,
              (SELECT COUNT(*)::int FROM messages m WHERE m.conversation_id = c.id AND m.sender_id = \(uuid: senderID)) AS sent
            FROM conversations c WHERE c.id = \(uuid: conversationID)
            """).first(decoding: R.self),
              !r.is_group, !r.accepted, let starter = r.request_from, let other = r.other_id
        else { return .open }
        if try await areConnected(senderID, other, mode: r.mode, on: db) { return .open }
        if starter.caseInsensitiveCompare(senderID) == .orderedSame {
            return decide(sent: r.sent)
        }
        try await accept(conversationID: conversationID, by: senderID, on: db)
        return .open
    }

    /// The starter's limit, as a pure rule.
    static func decide(sent: Int) -> Gate { sent >= limit ? .limitReached : .open }

    /// Accept a request — only its recipient can.
    static func accept(conversationID: String, by userID: String, on db: any SQLDatabase) async throws {
        try await db.raw("""
            UPDATE conversations SET request_accepted_at = NOW()
            WHERE id = \(uuid: conversationID) AND request_from IS NOT NULL AND request_from <> \(uuid: userID)
              AND request_accepted_at IS NULL
            """).run()
    }

    static let limitReason = "You can send up to 3 messages until they accept your request"
}

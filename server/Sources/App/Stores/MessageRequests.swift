import Vapor
import SQLKit

/// Message requests (migration 040): a 1-on-1 chat started by someone who
/// isn't the other person's friend waits in their "Waiting" list, and its
/// starter may send at most `limit` messages until it's accepted.
enum MessageRequests {
    static let limit = 3

    // MARK: - Connection SQL
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

    // MARK: - Sending gate
    enum Gate: Equatable {
        case open
        /// The starter has used up their messages; the reason to show.
        case limitReached
        /// The starter is under a moderation restriction (migration 089).
        case restricted
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
        // Writing to the official account (a support inbox) has no message limit.
        if try await OfficialAccount.isOfficial(other, on: db) { return .open }
        if starter.caseInsensitiveCompare(senderID) == .orderedSame {
            if try await isRestricted(senderID, mode: r.mode, on: db) { return .restricted }
            return decide(sent: r.sent)
        }
        try await accept(conversationID: conversationID, by: senderID, on: db)
        return .open
    }

    /// Whether someone other than `senderID` has written in this chat (a group
    /// counts too). The official account may only reply, never write first.
    static func otherHasWritten(conversationID: String, senderID: String, on db: any SQLDatabase) async throws -> Bool {
        struct R: Decodable { let one: Int }
        return try await db.raw("""
            SELECT 1 AS one FROM messages
            WHERE conversation_id = \(uuid: conversationID) AND sender_id <> \(uuid: senderID) LIMIT 1
            """).first(decoding: R.self) != nil
    }

    /// The starter's limit, as a pure rule.
    static func decide(sent: Int) -> Gate { sent >= limit ? .limitReached : .open }

    // MARK: - Accepting requests
    /// Who started an accepted request, and when it was accepted.
    struct Acceptance: Decodable { let request_from: String; let request_accepted_at: Date }

    /// Accept a request. Only its recipient can. Nil when nothing changed.
    @discardableResult
    static func accept(conversationID: String, by userID: String, on db: any SQLDatabase) async throws -> Acceptance? {
        try await db.raw("""
            UPDATE conversations SET request_accepted_at = NOW()
            WHERE id = \(uuid: conversationID) AND request_from IS NOT NULL AND request_from <> \(uuid: userID)
              AND request_accepted_at IS NULL
            RETURNING request_from::text AS request_from, request_accepted_at
            """).first(decoding: Acceptance.self)
    }

    /// Whether this chat is still a message request nobody has decided on.
    static func isPendingRequest(conversationID: String, on db: any SQLDatabase) async throws -> Bool {
        struct R: Decodable { let one: Int }
        return try await db.raw("""
            SELECT 1 AS one FROM conversations
            WHERE id = \(uuid: conversationID) AND request_from IS NOT NULL AND request_accepted_at IS NULL
            """).first(decoding: R.self) != nil
    }

    // MARK: - Pending request limits
    static let limitReason = "You can send up to 3 messages until they accept your request"
    /// Until a request is accepted, the sender can only write (up to `limit`
    /// messages) and the recipient can only accept or decline; either can open
    /// the other's profile. No nicknames, themes, reactions, pins, edits or
    /// meeting changes on either side, each of which would reach the other.
    static let pendingRequestReason = "You can do this once the message request is accepted"
    static let unrelatedReason = "You can only add friends or people who've accepted your messages"

    /// Among `ids`, the people `actor` may NOT put in a group or a space in
    /// `mode`: neither friends there, nor in a 1-on-1 chat that's past the
    /// request stage. Until a stranger is accepted, these are how they'd
    /// otherwise skip Waiting. Straight into your Messages via a group.
    static func unrelated(_ actor: String, _ ids: [UUID], mode: String, on db: any SQLDatabase) async throws -> Set<String> {
        guard !ids.isEmpty, ["hobby", "work"].contains(mode) else { return [] }
        let me = quoted(actor)
        let modeRef = "'\(mode)'"   // allowlisted above
        struct I: Decodable { let id: String }
        let rows = try await db.raw("""
            SELECT u.id::text AS id FROM unnest(\(bind: ids)) AS u(id)
            WHERE NOT \(unsafeRaw: connectedSQL(me, "u.id", mode: modeRef))
              AND NOT EXISTS (
                SELECT 1 FROM conversations c
                JOIN conversation_participants a ON a.conversation_id = c.id AND a.user_id = \(unsafeRaw: me)
                JOIN conversation_participants b ON b.conversation_id = c.id AND b.user_id = u.id
                WHERE c.is_group = FALSE AND c.mode = \(unsafeRaw: modeRef)
                  AND NOT \(unsafeRaw: pendingSQL(me: me, other: "u.id")))
            """).all(decoding: I.self)
        return Set(rows.map { $0.id.lowercased() })
    }

    // MARK: - Restrictions and links
    /// Restricted in the chat's mode (migration 125).
    static func isRestricted(_ userID: String, mode: String, on db: any SQLDatabase) async throws -> Bool {
        try await AccountRestrictions.active(userID, on: db)[mode] != nil
    }

    /// Whether `userID` is restricted in the mode of chat `conversationID`.
    static func isRestricted(in conversationID: String, userID: String, on db: any SQLDatabase) async throws -> Bool {
        struct M: Decodable { let mode: String }
        guard let mode = try await db.raw("SELECT mode FROM conversations WHERE id = \(uuid: conversationID)")
            .first(decoding: M.self)?.mode else { return false }
        return try await isRestricted(userID, mode: mode, on: db)
    }

    static let restrictedReason = "Your account can't message new people right now"

    static let newAccountLinkReason = "Links aren't available to new accounts yet. Try again in a couple of days."

    /// A brand-new account (under 48 hours) can't send a link to someone who
    /// hasn't accepted its chat: the commonest way spam and scams start.
    static func blocksNewAccountLink(conversationID: String, senderID: String, content: String?,
                                     on db: any SQLDatabase) async throws -> Bool {
        guard let content, ModerationRules.containsLink(content) else { return false }
        struct X: Decodable { let x: Int }
        return try await db.raw("""
            SELECT 1 AS x FROM conversations c, users u
            WHERE c.id = \(uuid: conversationID) AND u.id = \(uuid: senderID)
              AND NOT c.is_group AND c.request_from IS NOT NULL AND c.request_accepted_at IS NULL
              AND u.created_at > NOW() - make_interval(secs => \(bind: UserRateLimiter.newAccountAge)::float8)
            """).first(decoding: X.self) != nil
    }
}

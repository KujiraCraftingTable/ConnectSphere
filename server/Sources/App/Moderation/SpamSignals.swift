import Vapor
import SQLKit

/// Spam in chat, caught by what an account *does*, never by reading its
/// messages: the way WhatsApp and Messenger work without seeing inside private
/// chats. After a message to someone who hasn't accepted the chat, the
/// sender's last hour is counted: the same text to many strangers, links to
/// several, a new account messaging a crowd. A hit opens a case on the sender
/// (`Held by AI`), and in `enforce` mode pauses their features for a day until
/// a moderator looks.
enum SpamSignals {
    /// Set once at boot (`configure`): the live-chat path has no access to the environment.
    nonisolated(unsafe) static var enforcing = false

    struct Counts: Equatable, Sendable {
        /// Strangers sent exactly this text in the last hour.
        var sameTextChats = 0
        /// Strangers sent a link in the last hour.
        var linkChats = 0
        /// Strangers messaged at all in the last hour.
        var strangerChats = 0
        var isNewAccount = false
    }

    static let pauseHours = 24

    /// Why this looks like spam, or nil.
    static func reason(_ c: Counts) -> String? {
        if c.sameTextChats >= 5 { return "same_message" }
        if c.linkChats >= 3 { return "links" }
        if c.isNewAccount && c.strangerChats >= 8 { return "new_account_burst" }
        if c.strangerChats >= 25 { return "burst" }
        return nil
    }

    /// Looks at the sender's last hour after a message in `conversationID`.
    /// Only a message to a stranger — a chat the sender started that hasn't
    /// been accepted — counts. Never throws: a failed check mustn't fail the send.
    static func afterSend(senderID: String, conversationID: String, content: String?, mode: String?,
                          db: AppDatabase, hub: SocketHub, logger: Logger) async {
        let sdb = db.sql()
        do {
            // Only a chat the sender started with someone who hasn't accepted it.
            struct One: Decodable { let one: Int }
            guard try await sdb.raw("""
                SELECT 1 AS one FROM conversations
                WHERE id = \(uuid: conversationID) AND NOT is_group AND request_from = \(uuid: senderID) AND request_accepted_at IS NULL
                """).first(decoding: One.self) != nil else { return }
            struct R: Decodable { let same_text: Int; let links: Int; let strangers: Int; let new_account: Bool; let mode: String }
            let text = (content ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard let r = try await sdb.raw("""
                SELECT
                  (SELECT COUNT(DISTINCT m.conversation_id)::int FROM messages m JOIN conversations c ON c.id = m.conversation_id
                    WHERE m.sender_id = \(uuid: senderID) AND m.created_at > NOW() - INTERVAL '1 hour' AND NOT c.is_group
                      AND c.request_from = \(uuid: senderID) AND c.request_accepted_at IS NULL
                      AND \(bind: text) <> '' AND lower(btrim(m.content)) = \(bind: text)) AS same_text,
                  (SELECT COUNT(DISTINCT m.conversation_id)::int FROM messages m JOIN conversations c ON c.id = m.conversation_id
                    WHERE m.sender_id = \(uuid: senderID) AND m.created_at > NOW() - INTERVAL '1 hour' AND NOT c.is_group
                      AND c.request_from = \(uuid: senderID) AND c.request_accepted_at IS NULL
                      AND m.content ~* '(https?://|www\\.|t\\.me/|zalo\\.me/|bit\\.ly/)') AS links,
                  (SELECT COUNT(DISTINCT c.id)::int FROM conversations c JOIN messages m ON m.conversation_id = c.id
                    WHERE m.sender_id = \(uuid: senderID) AND m.created_at > NOW() - INTERVAL '1 hour' AND NOT c.is_group
                      AND c.request_from = \(uuid: senderID) AND c.request_accepted_at IS NULL) AS strangers,
                  (u.created_at > NOW() - make_interval(secs => \(bind: UserRateLimiter.newAccountAge)::float8)) AS new_account,
                  COALESCE((SELECT mode FROM conversations WHERE id = \(uuid: conversationID)), 'hobby') AS mode
                FROM users u WHERE u.id = \(uuid: senderID)
                """).first(decoding: R.self) else { return }
            let counts = Counts(sameTextChats: r.same_text, linkChats: r.links, strangerChats: r.strangers, isNewAccount: r.new_account)
            guard let why = reason(counts) else { return }
            try await flag(senderID: senderID, why: why, counts: counts, mode: r.mode == "work" ? "work" : "hobby",
                           db: db, hub: hub, logger: logger)
        } catch {
            logger.warning("spam signals failed for \(senderID): \(error)")
        }
    }

    private static func flag(senderID: String, why: String, counts: Counts, mode: String,
                             db: AppDatabase, hub: SocketHub, logger: Logger) async throws {
        let sdb = db.sql()
        guard let target = try await ModerationStore.target(.user, senderID, mode: mode, reporter: senderID, on: sdb) else { return }
        let verdict: [String: Any] = ["source": "spam_signals", "reason": why, "same_text": counts.sameTextChats,
                                      "links": counts.linkChats, "strangers": counts.strangerChats,
                                      "new_account": counts.isNewAccount, "shadow": !enforcing]
        let filed = try await ModerationStore.openAutoCase(type: .user, id: senderID, target: target, policy: .spam,
                                                           verdict: verdict, on: sdb)
        guard filed.opened else { return }   // already flagged and waiting for a person
        try await ModerationStore.log(caseID: filed.case_id, actor: nil, action: "spam_signal",
                                      detail: ["reason": why, "mode": enforcing ? "enforce" : "shadow"], on: sdb)
        logger.info("moderation: spam signal on \(senderID): \(why) (\(enforcing ? "enforce" : "shadow"))")
        guard enforcing else { return }
        struct U: Decodable { let id: String }
        let paused = try await sdb.raw("""
            UPDATE users SET restricted_until = NOW() + make_interval(hours => \(bind: pauseHours)::int)
            WHERE id = \(uuid: senderID) AND (restricted_until IS NULL OR restricted_until < NOW())
            RETURNING id::text AS id
            """).first(decoding: U.self)
        guard paused != nil else { return }
        // The case stands for the pause: keeping it (or an overturned appeal) lifts it.
        try await sdb.raw("UPDATE moderation_cases SET auto_hidden = TRUE WHERE id = \(uuid: filed.case_id)").run()
        await NotifyService.pushUserNotification(userID: senderID, type: "account_limited", groupTargetID: filed.case_id,
                                                 payload: ["caseId": filed.case_id, "hours": pauseHours],
                                                 on: sdb, hub: hub, logger: logger)
    }
}

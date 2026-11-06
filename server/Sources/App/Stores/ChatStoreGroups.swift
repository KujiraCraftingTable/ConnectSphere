import Vapor
import SQLKit

/// Validated meeting-proposal fields. The output of
/// `MessagesController.validateMeetingProposal`, consumed by the two writes
/// below. `startsAt` / `endsAt` are passed through as the caller's raw ISO
/// strings (Postgres parses them), exactly as Node does.
struct ValidatedMeeting: Sendable {
    var title: String
    var location: String?
    var startsAt: String
    var endsAt: String?
    var reminderOffset: String
    var reminderAt: String
}

/// Group management, group nicknames, alert-only block acknowledgement, and
/// meeting-proposal mutation.
extension ChatStore {

    // MARK: group conversations

    struct GroupConvRow: Content {
        var id: String
        var mode: String
        var is_group: Bool
        @NullCoded var name: String?
        @NullCoded var avatar_url: String?
        @NullCoded var avatar_color: String?
        var created_by: String
        var created_at: Date
    }

    /// `createGroupConversation`, INSERT the group row, then bulk-INSERT the
    /// creator (`owner`) + members (`member`). One transaction.
    static func createGroupConversation(creatorID: String, memberIDs: [String], mode: String,
                                        name: String, on db: AppDatabase) async throws -> GroupConvRow {
        var out: GroupConvRow?
        try await db.tx { t in
            out = try await t.raw("""
                INSERT INTO conversations (mode, is_group, name, created_by)
                VALUES (\(bind: mode), TRUE, \(bind: name), \(uuid: creatorID))
                RETURNING id::text AS id, mode, is_group, name, avatar_url, avatar_color,
                          created_by::text AS created_by, created_at
                """).first(decoding: GroupConvRow.self)
            let convID = out!.id
            var q: SQLQueryString = "INSERT INTO conversation_participants (conversation_id, user_id, role) VALUES "
            q = q + "(\(uuid: convID), \(uuid: creatorID), 'owner')"
            for uid in memberIDs { q = q + ", (\(uuid: convID), \(uuid: uid), 'member')" }
            try await t.raw(q).run()
        }
        return out!
    }

    // MARK: membership

    static func participantRole(_ conversationID: String, _ userID: String, on db: any SQLDatabase) async throws -> String? {
        struct R: Decodable { let role: String? }
        return try await db.raw("SELECT role FROM conversation_participants WHERE conversation_id = \(uuid: conversationID) AND user_id = \(uuid: userID)")
            .first(decoding: R.self)?.role ?? nil
    }

    /// Participant ids oldest-first. Used by `leaveGroup` to pick the
    /// earliest-joined remaining member for the auto-promote-on-leave case.
    static func participantsByJoin(_ conversationID: String, on db: any SQLDatabase) async throws -> [String] {
        struct R: Decodable { let user_id: String }
        return try await db.raw("SELECT user_id::text AS user_id FROM conversation_participants WHERE conversation_id = \(uuid: conversationID) ORDER BY joined_at ASC")
            .all(decoding: R.self).map(\.user_id)
    }

    static func addParticipants(_ conversationID: String, _ userIDs: [String], on db: any SQLDatabase) async throws {
        guard !userIDs.isEmpty else { return }
        var q: SQLQueryString = "INSERT INTO conversation_participants (conversation_id, user_id, role) VALUES "
        for (i, uid) in userIDs.enumerated() {
            q = q + (i == 0 ? "" : ", ") + "(\(uuid: conversationID), \(uuid: uid), 'member')"
        }
        q = q + " ON CONFLICT (conversation_id, user_id) DO NOTHING"
        try await db.raw(q).run()
    }

    static func removeParticipant(_ conversationID: String, _ userID: String, on db: any SQLDatabase) async throws {
        try await db.raw("DELETE FROM conversation_participants WHERE conversation_id = \(uuid: conversationID) AND user_id = \(uuid: userID)").run()
    }

    /// Atomic ownership swap: `from` → member, `to` → owner.
    static func transferOwnership(_ conversationID: String, from: String, to: String, on db: AppDatabase) async throws {
        try await db.tx { t in
            try await t.raw("UPDATE conversation_participants SET role = 'member' WHERE conversation_id = \(uuid: conversationID) AND user_id = \(uuid: from)").run()
            try await t.raw("UPDATE conversation_participants SET role = 'owner' WHERE conversation_id = \(uuid: conversationID) AND user_id = \(uuid: to)").run()
        }
    }

    /// `updateGroupInfo`, dynamic SET over `name` / `avatar_url` / `avatar_color`;
    /// only the columns the caller lists are touched (nil value = set NULL).
    static func updateGroupInfo(_ conversationID: String, sets: [(String, String?)], on db: any SQLDatabase) async throws {
        guard !sets.isEmpty else { return }
        var q: SQLQueryString = "UPDATE conversations SET "
        for (i, pair) in sets.enumerated() {
            q = q + (i == 0 ? "" : ", ") + "\(unsafeRaw: pair.0) = \(bind: pair.1)"
        }
        q = q + " WHERE id = \(uuid: conversationID)"
        try await db.raw(q).run()
    }

    // MARK: group nicknames (setter+target pair; 016_conversation_nicknames)

    static func setGroupNickname(_ conversationID: String, setterID: String, targetID: String, nickname: String, on db: any SQLDatabase) async throws {
        try await db.raw("""
            INSERT INTO conversation_nicknames (conversation_id, setter_id, target_id, nickname, updated_at)
            VALUES (\(uuid: conversationID), \(uuid: setterID), \(uuid: targetID), \(bind: nickname), NOW())
            ON CONFLICT (conversation_id, setter_id, target_id)
            DO UPDATE SET nickname = EXCLUDED.nickname, updated_at = NOW()
            """).run()
    }

    static func deleteGroupNickname(_ conversationID: String, setterID: String, targetID: String, on db: any SQLDatabase) async throws {
        try await db.raw("DELETE FROM conversation_nicknames WHERE conversation_id = \(uuid: conversationID) AND setter_id = \(uuid: setterID) AND target_id = \(uuid: targetID)").run()
    }

    // MARK: 1:1 theme + nickname (004_chat_settings)

    static func updateTheme(_ conversationID: String, theme: String?, on db: any SQLDatabase) async throws {
        try await db.raw("UPDATE conversations SET theme = \(bind: theme) WHERE id = \(uuid: conversationID)").run()
    }

    static func setNickname(_ conversationID: String, targetUserID: String, nickname: String?, on db: any SQLDatabase) async throws {
        try await db.raw("UPDATE conversation_participants SET nickname = \(bind: nickname) WHERE conversation_id = \(uuid: conversationID) AND user_id = \(uuid: targetUserID)").run()
    }

    // MARK: alert-only block acknowledgement (017_group_block_acknowledgement)

    /// Ids of other participants the caller has blocked (either direction).
    static func blockedIDsInConversation(_ conversationID: String, userID: String, on db: any SQLDatabase) async throws -> [String] {
        let others = try await participants(conversationID, on: db).filter { $0 != userID }
        var blocked: [String] = []
        for otherID in others where try await UserStore.isBlockedEitherWay(userID, otherID, on: db) {
            blocked.append(otherID)
        }
        return blocked
    }

    struct BlockAck: Decodable { let acked_blocked_ids: String; let acked_at: Date }
    static func getBlockAck(_ conversationID: String, userID: String, on db: any SQLDatabase) async throws -> BlockAck? {
        try await db.raw("SELECT acked_blocked_ids, acked_at FROM conversation_block_acks WHERE conversation_id = \(uuid: conversationID) AND user_id = \(uuid: userID)")
            .first(decoding: BlockAck.self)
    }

    static func setBlockAck(_ conversationID: String, userID: String, blockedIDs: [String], on db: any SQLDatabase) async throws {
        let snapshot = blockedIDs.sorted().joined(separator: ",")
        try await db.raw("""
            INSERT INTO conversation_block_acks (conversation_id, user_id, acked_blocked_ids, acked_at)
            VALUES (\(uuid: conversationID), \(uuid: userID), \(bind: snapshot), NOW())
            ON CONFLICT (conversation_id, user_id)
            DO UPDATE SET acked_blocked_ids = EXCLUDED.acked_blocked_ids, acked_at = NOW()
            """).run()
    }

    // MARK: meeting proposals (014_chat_meeting_proposals, 020_meeting_reminders)

    /// `getProposalByMessageId`, proposal + its message's conversation/sender/type,
    /// keyed by message id. Requires the message to not be recalled.
    struct ProposalRow: Decodable {
        let id: String?
        let status: String?
        let title: String?
        let location: String?
        let starts_at: Date?
        let ends_at: Date?
        let reminder_offset: String?
        let reminder_at: Date?
        let reminder_sent_at: Date?
        let message_id: String
        let conversation_id: String
        let sender_id: String
        let message_type: String
    }
    static func proposalByMessageID(_ messageID: String, on db: any SQLDatabase) async throws -> ProposalRow? {
        try await db.raw("""
            SELECT mp.id::text AS id, mp.status, mp.title, mp.location, mp.starts_at, mp.ends_at,
                   mp.reminder_offset, mp.reminder_at, mp.reminder_sent_at,
                   m.id::text AS message_id, m.conversation_id::text AS conversation_id,
                   m.sender_id::text AS sender_id, m.message_type
            FROM messages m
            LEFT JOIN message_meeting_proposals mp ON mp.message_id = m.id
            WHERE m.id = \(uuid: messageID) AND m.deleted_at IS NULL
            """).first(decoding: ProposalRow.self)
    }

    static func createMeetingProposalRow(messageID: String, _ v: ValidatedMeeting, on db: any SQLDatabase) async throws {
        try await db.raw("""
            INSERT INTO message_meeting_proposals
              (message_id, title, location, starts_at, ends_at, reminder_offset, reminder_at)
            VALUES (\(uuid: messageID), \(bind: v.title), \(bind: v.location),
                    \(bind: v.startsAt)::timestamptz, \(bind: v.endsAt)::timestamptz,
                    \(bind: v.reminderOffset), \(bind: v.reminderAt)::timestamptz)
            """).run()
    }

    /// Reschedule: update the proposal and clear all RSVPs + `reminder_sent_at`,
    /// in one transaction.
    static func updateMeetingProposalRow(_ proposalID: String, _ v: ValidatedMeeting, on db: AppDatabase) async throws {
        try await db.tx { t in
            try await t.raw("""
                UPDATE message_meeting_proposals
                SET title = \(bind: v.title), location = \(bind: v.location),
                    starts_at = \(bind: v.startsAt)::timestamptz, ends_at = \(bind: v.endsAt)::timestamptz,
                    reminder_offset = \(bind: v.reminderOffset), reminder_at = \(bind: v.reminderAt)::timestamptz,
                    reminder_sent_at = NULL, updated_at = NOW()
                WHERE id = \(uuid: proposalID)
                """).run()
            try await t.raw("DELETE FROM message_meeting_rsvps WHERE proposal_id = \(uuid: proposalID)").run()
        }
    }

    static func cancelMeetingProposalRow(_ proposalID: String, on db: any SQLDatabase) async throws {
        try await db.raw("UPDATE message_meeting_proposals SET status = 'cancelled', updated_at = NOW() WHERE id = \(uuid: proposalID)").run()
    }

    /// `markMessageDelivered`, upgrade one message to `delivered` for the
    /// caller. Returns the message's id + sender (for the realtime echo), or
    /// nil when nothing was upgraded (already delivered, own message, missing).
    static func markMessageDelivered(_ messageID: String, userID: String, on db: any SQLDatabase) async throws -> DeliveredRow? {
        try await db.raw("""
            WITH ins AS (
              INSERT INTO message_receipts (message_id, user_id, kind)
              SELECT m.id, \(uuid: userID), 'delivered' FROM messages m
              WHERE m.id = \(uuid: messageID) AND m.sender_id != \(uuid: userID)
              ON CONFLICT (message_id, user_id, kind) DO NOTHING RETURNING message_id
            )
            SELECT m.id::text AS id, m.sender_id::text AS sender_id FROM ins JOIN messages m ON m.id = ins.message_id
            """).first(decoding: DeliveredRow.self)
    }

    /// Guarded RSVP upsert. The write only lands while the proposal is still
    /// `active` (WHERE EXISTS on the source SELECT). Returns false when nothing
    /// was written (proposal cancelled/rescheduled).
    static func setMeetingRsvp(_ proposalID: String, userID: String, status: String, on db: any SQLDatabase) async throws -> Bool {
        struct R: Decodable { let proposal_id: String }
        return try await db.raw("""
            INSERT INTO message_meeting_rsvps (proposal_id, user_id, status)
            SELECT \(uuid: proposalID), \(uuid: userID), \(bind: status)
            WHERE EXISTS (SELECT 1 FROM message_meeting_proposals WHERE id = \(uuid: proposalID) AND status = 'active')
            ON CONFLICT (proposal_id, user_id) DO UPDATE SET status = \(bind: status), responded_at = NOW()
            RETURNING proposal_id::text AS proposal_id
            """).first(decoding: R.self) != nil
    }
}

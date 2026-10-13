import Vapor
import SQLKit

/// Polls in group chats (migration 052): a `poll` message whose content is
/// the question, with 2–6 options and an optional end. Each member has one
/// vote, which they can move or take back until the poll ends; unlike posts,
/// voters are shown, so the embedded poll lists who picked each option.
extension ChatStore {
    static let pollOptionCount = 2...6
    static let pollOptionMaxLength = 80
    static let pollQuestionMaxLength = 200

    struct ValidatedPoll: Equatable {
        let question: String
        let options: [String]
        let endsAt: Date?
    }

    /// Trims and checks a new poll; throws a 400 naming what's wrong.
    static func validatePoll(question: String?, options: [String]?, endsAt: String?,
                             now: Date = Date()) throws -> ValidatedPoll {
        guard let question = question?.trimmingCharacters(in: .whitespacesAndNewlines), !question.isEmpty else {
            throw Abort(.badRequest, reason: "A poll needs a question")
        }
        guard question.count <= pollQuestionMaxLength else {
            throw Abort(.badRequest, reason: "The question must be at most \(pollQuestionMaxLength) characters")
        }
        let cleaned = (options ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard pollOptionCount.contains(cleaned.count) else {
            throw Abort(.badRequest, reason: "A poll needs 2 to 6 options")
        }
        guard cleaned.allSatisfy({ $0.count <= pollOptionMaxLength }) else {
            throw Abort(.badRequest, reason: "Each option must be at most \(pollOptionMaxLength) characters")
        }
        guard Set(cleaned.map { $0.lowercased() }).count == cleaned.count else {
            throw Abort(.badRequest, reason: "Options must be different from each other")
        }
        var end: Date?
        if let endsAt, !endsAt.isEmpty {
            guard let parsed = MessagesController.parseDate(endsAt) else {
                throw Abort(.badRequest, reason: "Invalid poll end time")
            }
            guard parsed > now else { throw Abort(.badRequest, reason: "The poll must end in the future") }
            end = parsed
        }
        return ValidatedPoll(question: question, options: cleaned, endsAt: end)
    }

    /// The poll's row and its options, in one statement so a poll never
    /// exists half-made.
    static func createPoll(messageID: String, _ poll: ValidatedPoll, on db: any SQLDatabase) async throws {
        try await db.raw("""
            WITH p AS (
              INSERT INTO chat_polls (message_id, ends_at) VALUES (\(uuid: messageID), \(bind: poll.endsAt))
              RETURNING message_id
            )
            INSERT INTO chat_poll_options (message_id, text, position)
            SELECT p.message_id, o.text, (o.ord - 1)::smallint
            FROM p, unnest(\(bind: poll.options)::text[]) WITH ORDINALITY AS o(text, ord)
            """).run()
    }

    enum PollVoteResult { case changed, unchanged, notFound, invalidOption, ended }

    /// Sets `userID`'s vote to `optionID` — a first vote, or a move from
    /// another option — or takes it back when `optionID` is nil. Changes stop
    /// once the poll has ended. Run inside a transaction: the poll row is
    /// locked so the vote and the counts change together.
    static func votePoll(messageID: String, optionID: String?, userID: String,
                         on db: any SQLDatabase) async throws -> PollVoteResult {
        struct P: Decodable { let ends_at: Date?; let has_option: Bool }
        guard let poll = try await db.raw("""
            SELECT cp.ends_at, EXISTS(
              SELECT 1 FROM chat_poll_options o WHERE o.id = \(uuid: optionID ?? UUID().uuidString) AND o.message_id = cp.message_id
            ) AS has_option
            FROM chat_polls cp JOIN messages m ON m.id = cp.message_id AND m.deleted_at IS NULL
            WHERE cp.message_id = \(uuid: messageID)
            FOR UPDATE OF cp
            """).first(decoding: P.self) else { return .notFound }
        guard optionID == nil || poll.has_option else { return .invalidOption }
        if let end = poll.ends_at, end <= Date() { return .ended }

        struct V: Decodable { let option_id: UUID }
        let previous = try await db.raw("""
            SELECT option_id FROM chat_poll_votes
            WHERE message_id = \(uuid: messageID) AND user_id = \(uuid: userID)
            """).first(decoding: V.self)?.option_id
        let target = optionID.flatMap(UUID.init(uuidString:))
        guard previous != target else { return .unchanged }

        if let previous {
            try await db.raw("UPDATE chat_poll_options SET vote_count = vote_count - 1 WHERE id = \(uuid: previous.uuidString)").run()
        }
        switch (previous, target) {
        case (nil, let target?):
            try await db.raw("""
                INSERT INTO chat_poll_votes (message_id, option_id, user_id)
                VALUES (\(uuid: messageID), \(uuid: target.uuidString), \(uuid: userID))
                """).run()
        case (_?, let target?):
            try await db.raw("""
                UPDATE chat_poll_votes SET option_id = \(uuid: target.uuidString), voted_at = now()
                WHERE message_id = \(uuid: messageID) AND user_id = \(uuid: userID)
                """).run()
        case (_?, nil):
            try await db.raw("""
                DELETE FROM chat_poll_votes WHERE message_id = \(uuid: messageID) AND user_id = \(uuid: userID)
                """).run()
        case (nil, nil):
            return .unchanged
        }
        if let target {
            try await db.raw("UPDATE chat_poll_options SET vote_count = vote_count + 1 WHERE id = \(uuid: target.uuidString)").run()
        }
        return .changed
    }
}

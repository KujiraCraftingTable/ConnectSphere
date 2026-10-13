import Vapor
import SQLKit

/// Polls in group chats (migration 052): a `poll` message whose content is
/// the question, with 2–6 options and an optional end. As on posts each
/// member votes once and the vote is final; unlike posts, voters are shown,
/// so the embedded poll lists who picked each option.
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

    enum PollVoteResult { case voted, notFound, invalidOption, ended, alreadyVoted }

    /// Records `userID`'s vote for `optionID` — once per poll, before it ends.
    /// Run inside a transaction: the vote and the count change together.
    static func votePoll(messageID: String, optionID: String, userID: String,
                         on db: any SQLDatabase) async throws -> PollVoteResult {
        struct P: Decodable { let ends_at: Date?; let has_option: Bool }
        guard let poll = try await db.raw("""
            SELECT cp.ends_at, EXISTS(
              SELECT 1 FROM chat_poll_options o WHERE o.id = \(uuid: optionID) AND o.message_id = cp.message_id
            ) AS has_option
            FROM chat_polls cp JOIN messages m ON m.id = cp.message_id AND m.deleted_at IS NULL
            WHERE cp.message_id = \(uuid: messageID)
            FOR UPDATE OF cp
            """).first(decoding: P.self) else { return .notFound }
        guard poll.has_option else { return .invalidOption }
        if let end = poll.ends_at, end <= Date() { return .ended }

        struct V: Decodable { let option_id: String }
        guard try await db.raw("""
            INSERT INTO chat_poll_votes (message_id, option_id, user_id)
            VALUES (\(uuid: messageID), \(uuid: optionID), \(uuid: userID))
            ON CONFLICT DO NOTHING
            RETURNING option_id::text AS option_id
            """).first(decoding: V.self) != nil else { return .alreadyVoted }
        try await db.raw("UPDATE chat_poll_options SET vote_count = vote_count + 1 WHERE id = \(uuid: optionID)").run()
        return .voted
    }
}

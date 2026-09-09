import Vapor
import SQLKit

/// Port of `backend/src/models/pollModel.js`.
enum PollStore {
    static func createWithOptions(postID: String, options: [String], endsAt: String?, on db: any SQLDatabase) async throws {
        var q: SQLQueryString = "INSERT INTO poll_options (post_id, text, vote_count, position, ends_at) VALUES "
        for (i, text) in options.enumerated() {
            if i > 0 { q = q + ", " }
            q = q + "(\(uuid: postID), \(bind: text), 0, \(bind: i), \(bind: endsAt)::timestamptz)"
        }
        try await db.raw(q).run()
    }

    struct OptionRow: Decodable { let id: String }

    /// Throws 409 InlineError if the user already voted on any option of this poll.
    static func vote(pollOptionID: String, userID: String, on db: AppDatabase) async throws {
        let sdb = db.sql()
        let existing = try await sdb.raw("""
            SELECT pv.poll_option_id AS id
            FROM poll_votes pv
            JOIN poll_options po  ON po.id = pv.poll_option_id
            JOIN poll_options po2 ON po2.post_id = po.post_id AND po2.id = \(uuid: pollOptionID)
            WHERE pv.user_id = \(uuid: userID)
            """).first(decoding: OptionRow.self)
        if existing != nil {
            let err = Abort(.conflict, reason: "You have already voted on this poll")
            throw err
        }
        try await db.tx { t in
            try await t.raw("INSERT INTO poll_votes (poll_option_id, user_id) VALUES (\(uuid: pollOptionID), \(uuid: userID))").run()
            try await t.raw("UPDATE poll_options SET vote_count = vote_count + 1 WHERE id = \(uuid: pollOptionID)").run()
        }
    }

    static func optionIDs(postID: String, on db: any SQLDatabase) async throws -> [String] {
        try await db.raw("SELECT id FROM poll_options WHERE post_id = \(uuid: postID)")
            .all(decoding: OptionRow.self).map(\.id)
    }
}

/// Port of `backend/src/models/eventModel.js`.
enum EventStore {
    static func create(postID: String, title: String, location: String?, startsAt: String, endsAt: String?, on db: any SQLDatabase) async throws {
        try await db.raw("""
            INSERT INTO community_events (post_id, title, location, starts_at, ends_at)
            VALUES (\(uuid: postID), \(bind: title), \(bind: location), \(bind: startsAt)::timestamptz, \(bind: endsAt)::timestamptz)
            """).run()
    }

    struct EventByID: Decodable {
        let id: String
        let post_id: String
        let rsvp_count: Int
        let community_id: String?
    }
    static func byID(_ eventID: String, on db: any SQLDatabase) async throws -> EventByID? {
        try await db.raw("""
            SELECT e.id, e.post_id, e.rsvp_count, p.community_id
            FROM community_events e JOIN posts p ON p.id = e.post_id
            WHERE e.id = \(uuid: eventID)
            """).first(decoding: EventByID.self)
    }

    static func upsertRsvp(eventID: String, userID: String, status: String, on db: AppDatabase) async throws {
        struct S: Decodable { let status: String }
        let sdb = db.sql()
        let existing = try await sdb.raw("SELECT status FROM event_rsvps WHERE event_id = \(uuid: eventID) AND user_id = \(uuid: userID)")
            .first(decoding: S.self)
        try await db.tx { t in
            try await t.raw("""
                INSERT INTO event_rsvps (event_id, user_id, status) VALUES (\(uuid: eventID), \(uuid: userID), \(bind: status))
                ON CONFLICT (event_id, user_id) DO UPDATE SET status = \(bind: status), rsvp_at = NOW()
                """).run()
            let wasGoing = existing?.status == "going"
            let isGoing = status == "going"
            if !wasGoing && isGoing {
                try await t.raw("UPDATE community_events SET rsvp_count = rsvp_count + 1 WHERE id = \(uuid: eventID)").run()
            } else if wasGoing && !isGoing {
                try await t.raw("UPDATE community_events SET rsvp_count = GREATEST(0, rsvp_count - 1) WHERE id = \(uuid: eventID)").run()
            }
        }
    }
}

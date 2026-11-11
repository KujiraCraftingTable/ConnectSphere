import Vapor
import SQLKit

/// Polls.
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

    /// Sets `userID`'s vote on the poll of `postID` to `optionID`. A first
    /// vote or a move from another option, or takes it back when
    /// `optionID` is nil. One vote per person, as in chat polls; nothing
    /// changes once the poll has ended (409). The poll's post row is locked
    /// so the vote and the counts change together.
    static func setVote(postID: String, optionID: String?, userID: String, on db: AppDatabase) async throws {
        try await db.tx { t in
            struct P: Decodable { let ends_at: Date? }
            let poll = try await t.raw("""
                SELECT (SELECT po.ends_at FROM poll_options po WHERE po.post_id = p.id LIMIT 1) AS ends_at
                FROM posts p WHERE p.id = \(uuid: postID) FOR UPDATE
                """).first(decoding: P.self)
            if let end = poll?.ends_at, end <= Date() { throw Abort(.conflict, reason: "This poll has ended") }

            struct V: Decodable { let id: UUID }
            let previous = try await t.raw("""
                SELECT pv.poll_option_id AS id FROM poll_votes pv
                JOIN poll_options po ON po.id = pv.poll_option_id
                WHERE po.post_id = \(uuid: postID) AND pv.user_id = \(uuid: userID)
                """).first(decoding: V.self)?.id
            let target = optionID.flatMap(UUID.init(uuidString:))
            guard previous != target else { return }

            if let previous {
                try await t.raw("DELETE FROM poll_votes WHERE poll_option_id = \(uuid: previous.uuidString) AND user_id = \(uuid: userID)").run()
                try await t.raw("UPDATE poll_options SET vote_count = vote_count - 1 WHERE id = \(uuid: previous.uuidString)").run()
            }
            if let target {
                try await t.raw("INSERT INTO poll_votes (poll_option_id, user_id) VALUES (\(uuid: target.uuidString), \(uuid: userID))").run()
                try await t.raw("UPDATE poll_options SET vote_count = vote_count + 1 WHERE id = \(uuid: target.uuidString)").run()
            }
        }
    }

    /// The poll's option ids, lowercased. `::text` matters: decoding a uuid
    /// column straight into a String gives it in capitals, which never
    /// matched the lowercase id the client sends back.
    static func optionIDs(postID: String, on db: any SQLDatabase) async throws -> [String] {
        try await db.raw("SELECT id::text AS id FROM poll_options WHERE post_id = \(uuid: postID)")
            .all(decoding: OptionRow.self).map(\.id)
    }
}

/// Events.
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
            WHERE e.id = \(uuid: eventID) AND p.status = 'posted'
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

/// Job/Opportunity posts (Work mode only). "Interested" is a plain toggle
/// (row presence in job_interests), unlike event_rsvps' 3-state status.
enum JobStore {
    static let workFormats: Set<String> = ["onsite", "hybrid", "remote"]
    static let levels: Set<String> = ["intern", "fresher", "junior", "mid", "senior", "lead", "manager"]
    static let maxSkills = SkillStore.maxJob

    /// `job_posts.employment_type` CHECK values (migration 031).
    static let employmentTypes: Set<String> = ["full_time", "part_time", "contract", "internship", "remote"]

    /// The headline fields of a job, checked before the post row is written so
    /// a rejected job can't leave a bare post in the feed. Lengths are the
    /// column sizes; a longer value would be a 500 from the DB.
    struct Basics: Equatable {
        var title: String
        var company: String?
        var location: String?
        var employmentType: String?
        var salaryRange: String?
        /// `yyyy-MM-dd`.
        var applicationDeadline: String?
    }

    static func validateBasics(title: String?, company: String?, location: String?, employmentType: String?,
                               salaryRange: String?, applicationDeadline: String?) throws -> Basics {
        func text(_ raw: String?, max: Int, _ label: String) throws -> String? {
            let t = raw?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            if let t, t.count > max { throw Abort(.badRequest, reason: "\(label) must be at most \(max) characters") }
            return t
        }
        guard let title = try text(title, max: 150, "Job title") else { throw Abort(.badRequest, reason: "Job title is required") }
        var type: String?
        if let t = employmentType?.nilIfEmpty {
            guard employmentTypes.contains(t) else { throw Abort(.badRequest, reason: "Invalid employment type") }
            type = t
        }
        var deadline: String?
        if let raw = applicationDeadline?.nilIfEmpty {
            // Normalised to the calendar day so the later `::date` cast can't fail.
            let day = String(raw.prefix(10))
            // The formatter is lenient ("2027-02-30" parses as March 2); the round trip catches that.
            guard let parsed = PostService.dayFormatter.date(from: day), PostService.dayFormatter.string(from: parsed) == day else {
                throw Abort(.badRequest, reason: "Invalid application deadline")
            }
            deadline = day
        }
        return Basics(title: title, company: try text(company, max: 150, "Company"),
                      location: try text(location, max: 150, "Location"), employmentType: type,
                      salaryRange: try text(salaryRange, max: 100, "Salary range"), applicationDeadline: deadline)
    }

    /// The Jobs-tab details of a job, checked.
    struct Extra {
        var companyID: String?
        var careersURL: String?
        var workFormat: String?
        var level: String?
        var salaryMin: Int?
        var salaryMax: Int?
        var salaryNegotiable = false
        /// Where the job is, for distance (migration 129); its label replaces the typed location.
        var wardID: String?
        var wardLabel: String?
        /// The HR's own uploaded job description PDF; checked in `PostService`.
        var jdPath: String?
        var skills: [String] = []
    }

    /// Checks the details. The company isn't taken from them: it's the poster's
    /// verified HR company (see `PostService.createJobPost`).
    static func validateDetails(_ d: PostsController.CreateBody.JobDataIn?,
                                on db: any SQLDatabase) async throws -> Extra {
        var extra = Extra()
        // Only required for now, not checked against the company's domain (KNOWN_GAPS).
        let careers = d?.careersUrl?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        guard let careers else { throw Abort(.badRequest, reason: "Add the job's link on your company careers page") }
        guard careers.count <= HRStore.maxCareersURL else {
            throw Abort(.badRequest, reason: "The careers link must be at most \(HRStore.maxCareersURL) characters")
        }
        extra.careersURL = careers
        guard let d else { return extra }
        if let f = d.workFormat?.nilIfEmpty {
            guard workFormats.contains(f) else { throw Abort(.badRequest, reason: "Invalid work format") }
            extra.workFormat = f
        }
        if let l = d.level?.nilIfEmpty {
            guard levels.contains(l) else { throw Abort(.badRequest, reason: "Invalid level") }
            extra.level = l
        }
        for s in [d.salaryMin, d.salaryMax] {
            if let s, !(0...100_000).contains(s) { throw Abort(.badRequest, reason: "Salary must be 0–100,000 (million VND)") }
        }
        if let lo = d.salaryMin, let hi = d.salaryMax, lo > hi {
            throw Abort(.badRequest, reason: "The minimum salary can't be above the maximum")
        }
        // Negotiable stands in for the range, never beside it.
        extra.salaryNegotiable = d.salaryNegotiable ?? false
        extra.salaryMin = extra.salaryNegotiable ? nil : d.salaryMin
        extra.salaryMax = extra.salaryNegotiable ? nil : d.salaryMax
        if let w = d.wardId?.trimmingCharacters(in: .whitespaces).nilIfEmpty {
            struct W: Decodable { let id: String; let label: String }
            guard UUID(uuidString: w) != nil, let ward = try await db.raw("""
                SELECT id::text AS id, full_name || ', ' || province_name AS label FROM vn_wards WHERE id = \(uuid: w)
                """).first(decoding: W.self) else { throw Abort(.badRequest, reason: "Unknown ward") }
            extra.wardID = ward.id
            extra.wardLabel = ward.label
        }
        extra.jdPath = d.jdPath?.trimmingCharacters(in: .whitespaces).nilIfEmpty
        // Without a place a job can never be "near", so only remote work skips it.
        guard extra.workFormat == "remote" || extra.wardID != nil else {
            throw Abort(.badRequest, reason: "Pick the ward where the job is")
        }
        // Same catalogue as profiles, so job matching compares like with like.
        extra.skills = try await SkillStore.cleanPicks(d.skills ?? [], userID: nil, limit: maxSkills, on: db)
        return extra
    }

    static func create(postID: String, title: String, company: String?, location: String?,
                        employmentType: String?, salaryRange: String?, applicationDeadline: String?,
                        extra: Extra = Extra(), on db: any SQLDatabase) async throws {
        struct R: Decodable { let id: String }
        let jobID = try await db.raw("""
            INSERT INTO job_posts (post_id, title, company, location, employment_type, salary_range, application_deadline,
                                   company_id, work_format, level, salary_min, salary_max, careers_url, salary_negotiable, ward_id, jd_path)
            VALUES (\(uuid: postID), \(bind: title), \(bind: company), \(bind: extra.wardLabel ?? location),
                    \(bind: employmentType), \(bind: salaryRange), \(bind: applicationDeadline)::date,
                    \(uuid: extra.companyID), \(bind: extra.workFormat), \(bind: extra.level),
                    \(bind: extra.salaryMin), \(bind: extra.salaryMax), \(bind: extra.careersURL), \(bind: extra.salaryNegotiable), \(uuid: extra.wardID), \(bind: extra.jdPath))
            RETURNING id::text AS id
            """).first(decoding: R.self)!.id
        if !extra.skills.isEmpty {
            try await db.raw("""
                INSERT INTO job_skills (job_id, skill) SELECT \(uuid: jobID), unnest(\(bind: extra.skills)::text[])
                ON CONFLICT DO NOTHING
                """).run()
        }
    }

    struct JobByID: Decodable {
        let id: String
        let post_id: String
        let interested_count: Int
        let community_id: String?
    }
    static func byID(_ jobID: String, on db: any SQLDatabase) async throws -> JobByID? {
        try await db.raw("""
            SELECT j.id, j.post_id, j.interested_count, p.community_id
            FROM job_posts j JOIN posts p ON p.id = j.post_id
            WHERE j.id = \(uuid: jobID) AND p.status = 'posted'
            """).first(decoding: JobByID.self)
    }

    static func setInterested(jobID: String, userID: String, interested: Bool, on db: AppDatabase) async throws {
        struct Exists: Decodable { let x: Int }
        let sdb = db.sql()
        let wasInterested = try await sdb.raw(
            "SELECT 1 AS x FROM job_interests WHERE job_id = \(uuid: jobID) AND user_id = \(uuid: userID)"
        ).first(decoding: Exists.self) != nil
        try await db.tx { t in
            if interested {
                try await t.raw("""
                    INSERT INTO job_interests (job_id, user_id) VALUES (\(uuid: jobID), \(uuid: userID))
                    ON CONFLICT (job_id, user_id) DO NOTHING
                    """).run()
            } else {
                try await t.raw("DELETE FROM job_interests WHERE job_id = \(uuid: jobID) AND user_id = \(uuid: userID)").run()
            }
            if !wasInterested && interested {
                try await t.raw("UPDATE job_posts SET interested_count = interested_count + 1 WHERE id = \(uuid: jobID)").run()
            } else if wasInterested && !interested {
                try await t.raw("UPDATE job_posts SET interested_count = GREATEST(0, interested_count - 1) WHERE id = \(uuid: jobID)").run()
            }
        }
    }
}

import Vapor
import SQLKit

/// `seed-demo seed` writes the 40 demo people from `Seeds/demo-hobby.json` and
/// `Seeds/demo-work.json`: 20 Hobby and 20 Work, four groups each, every bio,
/// post and comment hand-written and unique. Likes, follows, connections and
/// endorsements are real rows, drawn with a fixed seed so a re-seed comes out
/// the same; counters are recounted from those rows. A few seed people also
/// follow, like and comment on real accounts (`real` in the fixtures).
///
/// `seed-demo embed` then builds each seed profile's and post's chunk (with its
/// translation) and the posts' AI tags. The slow part, kept separate so it can
/// be re-run until everything has a vector.
extension SeedDemoCommand {
    // MARK: - Fixture

    struct Fixture: Decodable {
        var people: [Person]
        var companies: [Company]?
        var jobs: [Job]?
        var real: Real?
    }

    struct Person: Decodable {
        var u: String, n: String, g: String, dob: String, loc: String, grp: String, bio: String
        var interests: [String]?
        var title: String?, company: String?
        var skills: [String]?
        var exp: [Experience]?
        var edu: [Education]?
        var posts: [Post]
    }

    struct Post: Decodable { var d: Int; var t: String; var c: [Comment]? }

    /// `[author, text]`, or `[author, text, index of the comment it answers]`.
    struct Comment: Decodable {
        var by: String, text: String, replyTo: Int?
        init(from decoder: any Decoder) throws {
            var c = try decoder.unkeyedContainer()
            by = try c.decode(String.self)
            text = try c.decode(String.self)
            replyTo = c.isAtEnd ? nil : try c.decodeIfPresent(Int.self)
        }
    }

    /// `[company, title, employment type, location type, "YYYY-MM", "YYYY-MM" | null, description]`
    struct Experience: Decodable {
        var company: String, title: String, type: String, locationType: String
        var start: String, end: String?, description: String
        init(from decoder: any Decoder) throws {
            var c = try decoder.unkeyedContainer()
            company = try c.decode(String.self); title = try c.decode(String.self)
            type = try c.decode(String.self); locationType = try c.decode(String.self)
            start = try c.decode(String.self); end = try c.decodeIfPresent(String.self)
            description = try c.decode(String.self)
        }
    }

    /// `[school, school type, major, start year, end year]`
    struct Education: Decodable {
        var school: String, type: String, major: String, start: Int, end: Int
        init(from decoder: any Decoder) throws {
            var c = try decoder.unkeyedContainer()
            school = try c.decode(String.self); type = try c.decode(String.self); major = try c.decode(String.self)
            start = try c.decode(Int.self); end = try c.decode(Int.self)
        }
    }

    struct Company: Decodable {
        var key: String, name: String, slug: String, owner: String, admins: [String]
        var industry: String, size: String, hq: String, founded: Int, website: String, about: String
    }

    struct Job: Decodable {
        var by: String, company: String?, company_name: String?, d: Int, t: String
        var title: String, location: String, type: String, format: String, level: String
        var min: Int, max: Int, deadline: Int, skills: [String]
    }

    /// Seed person → real username pairs; `comment` adds the text.
    struct Real: Decodable { var follow: [[String]]; var like: [[String]]; var comment: [[String]] }

    static let seedEmailDomain = "seed.connectsphere.test"
    static let avatarColors = ["#1877F2", "#E4405F", "#2EB67D", "#F59E0B", "#8B5CF6", "#0EA5E9", "#EF4444", "#14B8A6"]

    // MARK: - Seed

    func seed(_ context: CommandContext) async throws {
        let app = context.application
        let db = app.db.sql()
        let dir = app.directory.workingDirectory + "Seeds/"
        let decoder = JSONDecoder()
        let hobby = try decoder.decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: dir + "demo-hobby.json")))
        let work = try decoder.decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: dir + "demo-work.json")))
        let people = hobby.people.map { ($0, "hobby") } + work.people.map { ($0, "work") }

        if let problem = Self.fixtureProblem(hobby: hobby, work: work) {
            context.console.error("Fixture problem: \(problem)")
            return
        }
        struct Taken: Decodable { let username: String }
        let taken = try await db.raw("SELECT username FROM users WHERE username = ANY(\(bind: people.map(\.0.u)))")
            .all(decoding: Taken.self)
        guard taken.isEmpty else {
            context.console.error("Already in the database: \(taken.map(\.username).joined(separator: ", ")). Run `seed-demo wipe --commit` first.")
            return
        }

        // Catalogue spelling for interests and skills, specific items resolved
        // ("Gaming · Valorant"), before anything is written.
        let interestEntries = try await InterestStore.entries(on: db)
        let skillEntries = try await SkillStore.entries(on: db)
        var interestsOf: [String: [String]] = [:]
        var skillsOf: [String: [String]] = [:]
        for (p, _) in people {
            if let items = p.interests {
                let checked = try InterestRules.normalize(items, entries: interestEntries, existing: [])
                var picks = checked.picks
                for (index, base, specific) in checked.specifics {
                    let name = try await InterestStore.resolveSpecific(
                        specific, entries: interestEntries, cfg: app.ollama, client: app.http.client.shared, on: db, logger: app.logger)
                    picks[index] = name.map { base + InterestStore.separator + $0 } ?? base
                    if name == nil { context.console.warning("\(p.u): \"\(specific)\" not found, kept \(base)") }
                }
                interestsOf[p.u] = picks
            }
            if let items = p.skills {
                skillsOf[p.u] = try SkillRules.normalize(items, entries: skillEntries, existing: [], limit: SkillStore.maxProfile)
            }
        }
        var jobSkills: [[String]] = []
        for job in work.jobs ?? [] {
            jobSkills.append(try SkillRules.normalize(job.skills, entries: skillEntries, existing: [], limit: SkillStore.maxJob))
        }

        let (finalInterests, finalSkills, finalJobSkills) = (interestsOf, skillsOf, jobSkills)
        let lines = try await app.db.withTransaction { t -> [String] in
            var rng = SeededGenerator(seed: 20261103)
            var ids: [String: String] = [:]
            var modeOf: [String: String] = [:]
            for (i, (p, mode)) in people.enumerated() {
                ids[p.u] = try await Self.insertPerson(p, mode: mode, color: Self.avatarColors[i % Self.avatarColors.count],
                                                       interests: finalInterests[p.u] ?? [], skills: finalSkills[p.u] ?? [], on: t)
                modeOf[p.u] = mode
            }

            var companyIDs: [String: String] = [:]
            for c in work.companies ?? [] {
                companyIDs[c.name] = try await Self.insertCompany(c, ids: ids, on: t)
            }
            for (p, _) in people {
                try await Self.insertCareer(p, userID: ids[p.u]!, companyIDs: companyIDs, on: t)
            }

            // Posts and their comments.
            var postsOf: [String: [(id: String, at: Date)]] = [:]
            var commentsOn: [String: [(id: String, author: String)]] = [:]
            var commentCount = 0
            for (p, mode) in people {
                for post in p.posts {
                    let at = Self.postTime(daysAgo: post.d, rng: &rng)
                    let postID = try await Self.insertPost(post.t, author: ids[p.u]!, mode: mode, type: "text", at: at, on: t)
                    postsOf[p.u, default: []].append((postID, at))
                    var placed: [String] = []
                    for (k, c) in (post.c ?? []).enumerated() {
                        let replyTo = c.replyTo.map { placed[$0] }
                        let when = min(at.addingTimeInterval(Double(k + 1) * Double(Int.random(in: 600...7200, using: &rng))),
                                       Date().addingTimeInterval(-60))
                        let id = try await Self.insertComment(c.text, post: postID, author: ids[c.by]!, replyTo: replyTo, at: when, on: t)
                        placed.append(id)
                        commentsOn[postID, default: []].append((id, c.by))
                        commentCount += 1
                    }
                }
            }
            let dayFormat = DateFormatter()
            dayFormat.dateFormat = "yyyy-MM-dd"
            for (job, skills) in zip(work.jobs ?? [], finalJobSkills) {
                let at = Self.postTime(daysAgo: job.d, rng: &rng)
                let postID = try await Self.insertPost(job.t, author: ids[job.by]!, mode: "work", type: "job", at: at, on: t)
                postsOf[job.by, default: []].append((postID, at))
                let company = (work.companies ?? []).first { $0.key == job.company }
                var extra = JobStore.Extra()
                extra.companyID = company.flatMap { companyIDs[$0.name] }
                extra.workFormat = job.format
                extra.level = job.level
                extra.salaryMin = job.min
                extra.salaryMax = job.max
                extra.skills = skills
                let companyName = company?.name ?? job.company_name ?? "Company"
                extra.careersURL = (company?.website ?? "https://" + Self.slugDomain(companyName)) + "/careers"
                // An office job sits in its poster's ward, so "near" (ward distance,
                // migration 129) works on demo data too.
                if job.format != "remote" {
                    struct W: Decodable { let id: String; let label: String }
                    if let w = try await t.raw("""
                        SELECT w.id::text AS id, w.full_name || ', ' || w.province_name AS label
                        FROM users u JOIN vn_wards w ON w.id = u.ward_id WHERE u.id = \(uuid: ids[job.by]!)
                        """).first(decoding: W.self) {
                        extra.wardID = w.id
                        extra.wardLabel = w.label
                    }
                }
                // Only verified HR post jobs (migration 126): the demo posters
                // are, past their trial. One HR per company (tax code), so a
                // second poster for the same company stays a plain user.
                try await t.raw("""
                    INSERT INTO recruiters (user_id, company_name, tax_code, company_id, trial_left)
                    VALUES (\(uuid: ids[job.by]!), \(bind: companyName), \(bind: Self.demoTaxCode(companyName)),
                            \(uuid: extra.companyID), 0)
                    ON CONFLICT DO NOTHING
                    """).run()
                try await JobStore.create(postID: postID, title: job.title, company: companyName,
                                          location: job.location, employmentType: job.type, salaryRange: nil,
                                          applicationDeadline: dayFormat.string(from: Date().addingTimeInterval(Double(job.deadline) * 86_400)),
                                          extra: extra, on: t)
            }

            // Who likes what: mostly their own group, a little across groups,
            // and commenters usually like the post they answered.
            var likes = 0
            for (p, mode) in people {
                let samePeople = people.filter { $0.1 == mode && $0.0.u != p.u }.map(\.0)
                for post in postsOf[p.u] ?? [] {
                    let commenters = Set((commentsOn[post.id] ?? []).map(\.author))
                    for other in samePeople {
                        let chance = commenters.contains(other.u) ? 0.8 : other.grp == p.grp ? 0.55 : 0.12
                        guard Double.random(in: 0..<1, using: &rng) < chance else { continue }
                        let likedAt = min(post.at.addingTimeInterval(Double(Int.random(in: 300...86_400, using: &rng))), Date())
                        try await t.raw("""
                            INSERT INTO post_likes (post_id, user_id, created_at)
                            VALUES (\(uuid: post.id), \(uuid: ids[other.u]!), \(bind: likedAt))
                            ON CONFLICT DO NOTHING
                            """).run()
                        likes += 1
                    }
                    // The author likes most comments on their own post.
                    for c in commentsOn[post.id] ?? [] where c.author != p.u && Double.random(in: 0..<1, using: &rng) < 0.6 {
                        try await t.raw("INSERT INTO comment_likes (comment_id, user_id) VALUES (\(uuid: c.id), \(uuid: ids[p.u]!)) ON CONFLICT DO NOTHING").run()
                    }
                }
            }

            // Connections: everyone in a group, plus one across groups each.
            var pairs = Set<[String]>()
            for mode in ["hobby", "work"] {
                let modePeople = people.filter { $0.1 == mode }.map(\.0)
                for (i, a) in modePeople.enumerated() {
                    for b in modePeople[(i + 1)...] where a.grp == b.grp { pairs.insert([a.u, b.u]) }
                    if let b = modePeople.filter({ $0.grp != a.grp }).randomElement(using: &rng) {
                        pairs.insert([a.u, b.u].sorted())
                    }
                }
            }
            for pair in pairs.sorted(by: { $0.joined() < $1.joined() }) {
                let (a, b) = (ids[pair[0]]!, ids[pair[1]]!)
                let mode = modeOf[pair[0]]!
                try await t.raw("""
                    INSERT INTO connections (requester_id, addressee_id, mode, status)
                    VALUES (\(uuid: a), \(uuid: b), \(bind: mode), 'accepted') ON CONFLICT DO NOTHING
                    """).run()
                for (from, to) in [(a, b), (b, a)] {
                    try await t.raw("""
                        INSERT INTO follows (follower_id, followee_id, mode) VALUES (\(uuid: from), \(uuid: to), \(bind: mode))
                        ON CONFLICT DO NOTHING
                        """).run()
                }
                // Connected Work people vouch for a couple of each other's skills.
                if mode == "work" {
                    for (endorser, owner) in [(pair[0], pair[1]), (pair[1], pair[0])] {
                        let pick = Array((finalSkills[owner] ?? []).shuffled(using: &rng).prefix(2))
                        try await t.raw("""
                            INSERT INTO skill_endorsements (skill_id, endorser_id)
                            SELECT id, \(uuid: ids[endorser]!) FROM user_skills
                            WHERE user_id = \(uuid: ids[owner]!) AND skill = ANY(\(bind: pick))
                            ON CONFLICT DO NOTHING
                            """).run()
                    }
                }
            }
            // Work people follow the company they work at, plus a couple more.
            for (p, mode) in people where mode == "work" {
                let others = Array(companyIDs.keys.sorted().shuffled(using: &rng).prefix(2))
                for name in Set(others + [p.company ?? ""]) {
                    guard let companyID = companyIDs[name] else { continue }
                    try await t.raw("""
                        INSERT INTO company_followers (company_id, user_id) VALUES (\(uuid: companyID), \(uuid: ids[p.u]!))
                        ON CONFLICT DO NOTHING
                        """).run()
                }
            }

            let realLines = try await Self.touchRealAccounts([hobby.real, work.real].compactMap { $0 },
                                                             ids: ids, modeOf: modeOf, on: t)
            var lines = ["people: \(people.count)", "companies: \(companyIDs.count)",
                         "posts: \(postsOf.values.map(\.count).reduce(0, +))", "comments: \(commentCount)",
                         "likes: \(likes)", "connections: \(pairs.count)"] + realLines
            lines += try await Self.recountCounters(on: t)
            return lines
        }
        lines.forEach { context.console.info($0) }
        context.console.info("Seed committed. Next: `swift run App seed-demo embed` for vectors and AI tags.")
    }

    // MARK: - Embed

    /// Builds every seed profile's and post's chunk, and each post's AI tags.
    /// Safe to re-run: unchanged chunks are skipped by their source hash.
    func embed(_ context: CommandContext) async throws {
        let app = context.application
        let db = app.db.sql()
        struct Row: Decodable { let id: String; let content: String? }
        let users = try await db.raw("""
            SELECT id::text AS id, NULL::text AS content FROM users WHERE password_hash = 'SEED_DATA' ORDER BY username
            """).all(decoding: Row.self)
        let posts = try await db.raw("""
            SELECT p.id::text AS id, p.content FROM posts p JOIN users u ON u.id = p.author_id
            WHERE u.password_hash = 'SEED_DATA' AND p.status = 'posted'
            ORDER BY p.created_at
            """).all(decoding: Row.self)
        context.console.info("Embedding \(users.count) profiles and \(posts.count) posts…")
        var failed = 0
        for (i, u) in users.enumerated() {
            do { _ = try await ChunkService.buildProfileChunk(u.id, cfg: app.ollama, on: db, logger: app.logger) }
            catch { failed += 1; app.logger.warning("Profile \(u.id): \(error)") }
            if (i + 1) % 10 == 0 { context.console.info("profiles \(i + 1)/\(users.count)") }
        }
        for (i, p) in posts.enumerated() {
            do {
                let tagged = try await db.raw("SELECT COUNT(*)::int AS n FROM post_tags WHERE post_id = \(uuid: p.id) AND source = 'ai'")
                    .first(decoding: Counted.self)?.n ?? 0
                if tagged == 0 {
                    try await PostTagExtractService.extractAndSave(app.ollama, postID: p.id, content: p.content ?? "",
                                                                   client: app.http.client.shared, on: db, logger: app.logger)
                }
                _ = try await ChunkService.buildPostChunk(p.id, cfg: app.ollama, on: db, logger: app.logger)
            } catch { failed += 1; app.logger.warning("Post \(p.id): \(error)") }
            if (i + 1) % 20 == 0 { context.console.info("posts \(i + 1)/\(posts.count)") }
        }
        context.console.info(failed == 0 ? "Embedding done." : "Embedding done with \(failed) failures, re-run to retry them.")
    }

    private struct Counted: Decodable { let n: Int }

    // MARK: - Checks

    /// Nil when the fixtures are usable: unique usernames and texts, every
    /// commenter a seed person, every reply pointing at an earlier comment.
    static func fixtureProblem(hobby: Fixture, work: Fixture) -> String? {
        let people = hobby.people + work.people
        let names = people.map(\.u)
        guard Set(names).count == names.count else { return "duplicate usernames" }
        let usernameRule = try! Regex("^[a-z0-9_]{3,30}$")
        if let bad = names.first(where: { $0.wholeMatch(of: usernameRule) == nil }) { return "bad username \(bad)" }
        let known = Set(names)
        var texts = people.map(\.bio) + (work.jobs ?? []).map(\.t)
        for p in people {
            for post in p.posts {
                texts.append(post.t)
                for (k, c) in (post.c ?? []).enumerated() {
                    guard known.contains(c.by) else { return "\(p.u): unknown commenter \(c.by)" }
                    if let r = c.replyTo, !(0..<k).contains(r) { return "\(p.u): reply \(k) points at \(r)" }
                    texts.append(c.text)
                }
            }
        }
        var seen = Set<String>()
        for text in texts where !seen.insert(text.lowercased()).inserted { return "repeated text: \(text.prefix(60))" }
        for job in work.jobs ?? [] where !known.contains(job.by) { return "job by unknown \(job.by)" }
        return nil
    }

    // MARK: - Writes

    /// Every demo account lives in a Ho Chi Minh City ward, picked from a hash
    /// of its username, so distance search has people to find around the
    /// developer (migration 103 does the same for older accounts).
    private static func seedWardSQL(_ username: String) -> SQLQueryString {
        """
        SELECT h.id FROM (
          SELECT id, (row_number() OVER (ORDER BY code) - 1) AS n, count(*) OVER () AS total
          FROM vn_wards WHERE province_name_en = 'Ho Chi Minh City') h
        WHERE h.n = (hashtext(\(bind: username))::bigint & 2147483647) % h.total
        """
    }

    private static func insertPerson(_ p: Person, mode: String, color: String, interests: [String], skills: [String],
                                     on t: any SQLDatabase) async throws -> String {
        struct R: Decodable { let id: String }
        let hobby = mode == "hobby"
        let id = try await t.raw("""
            INSERT INTO users (username, password_hash, display_name, bio, email, gender, dob, age, dob_visibility,
                               location, ward_id, is_setup, default_mode, avatar_color,
                               hobby_display_name, hobby_bio, work_display_name, work_bio, job_title, company,
                               created_at, updated_at)
            VALUES (\(bind: p.u), 'SEED_DATA', \(bind: p.n), \(bind: p.bio), \(bind: "\(p.u)@\(seedEmailDomain)"),
                    \(bind: p.g), \(bind: p.dob)::date, date_part('year', age(\(bind: p.dob)::date))::int, 'private',
                    'Ho Chi Minh', (\(seedWardSQL(p.u))), TRUE, \(bind: mode), \(bind: color),
                    \(bind: hobby ? p.n : nil), \(bind: hobby ? p.bio : nil),
                    \(bind: hobby ? nil : p.n), \(bind: hobby ? nil : p.bio), \(bind: p.title), \(bind: p.company),
                    NOW() - INTERVAL '75 days', NOW() - INTERVAL '75 days')
            RETURNING id::text AS id
            """).first(decoding: R.self)!.id
        if !interests.isEmpty {
            try await t.raw("INSERT INTO user_interests (user_id, interest) SELECT \(uuid: id), unnest(\(bind: interests)::text[])").run()
        }
        if !skills.isEmpty {
            try await t.raw("INSERT INTO user_skills (user_id, skill) SELECT \(uuid: id), unnest(\(bind: skills)::text[])").run()
        }
        return id
    }

    private static func insertCompany(_ c: Company, ids: [String: String], on t: any SQLDatabase) async throws -> String {
        struct R: Decodable { let id: String }
        let id = try await t.raw("""
            INSERT INTO companies (name, slug, about, industry, size, website, headquarters, founded_year, created_by)
            VALUES (\(bind: c.name), \(bind: c.slug), \(bind: c.about), \(bind: c.industry), \(bind: c.size),
                    \(bind: c.website), \(bind: c.hq), \(bind: c.founded), \(uuid: ids[c.owner]!))
            RETURNING id::text AS id
            """).first(decoding: R.self)!.id
        for (username, role) in [(c.owner, "owner")] + c.admins.map({ ($0, "admin") }) {
            try await t.raw("""
                INSERT INTO company_admins (company_id, user_id, role) VALUES (\(uuid: id), \(uuid: ids[username]!), \(bind: role))
                """).run()
        }
        return id
    }

    private static func insertCareer(_ p: Person, userID: String, companyIDs: [String: String], on t: any SQLDatabase) async throws {
        for e in p.exp ?? [] {
            try await t.raw("""
                INSERT INTO work_experiences (user_id, company_id, company_name, title, employment_type, location, location_type,
                                              start_month, end_month, description)
                VALUES (\(uuid: userID), \(uuid: companyIDs[e.company]), \(bind: e.company), \(bind: e.title), \(bind: e.type),
                        \(bind: p.loc), \(bind: e.locationType), \(bind: e.start + "-01")::date,
                        \(bind: e.end.map { $0 + "-01" })::date, \(bind: e.description))
                """).run()
        }
        for e in p.edu ?? [] {
            try await t.raw("""
                INSERT INTO educations (user_id, school_name, school_type, major, start_year, end_year)
                VALUES (\(uuid: userID), \(bind: e.school), \(bind: e.type), \(bind: e.major), \(bind: e.start), \(bind: e.end))
                """).run()
        }
    }

    /// Hashtags typed in the text become the post's own tags, as the composer
    /// keeps them apart from the content.
    static func splitHashtags(_ text: String) -> (content: String, tags: [String]) {
        let tagPattern = try! Regex(#"#([\p{L}\p{N}_]+)"#)
        var tags: [String] = []
        for match in text.matches(of: tagPattern) {
            guard let captured = match.output[1].substring else { continue }
            let tag = String(captured).lowercased()
            if !tags.contains(tag) { tags.append(tag) }
        }
        let content = text.replacing(tagPattern, with: "")
            .split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return (content, tags)
    }

    private static func insertPost(_ text: String, author: String, mode: String, type: String, at: Date,
                                   on t: any SQLDatabase) async throws -> String {
        struct R: Decodable { let id: String }
        let (content, tags) = splitHashtags(text)
        let id = try await t.raw("""
            INSERT INTO posts (author_id, content, mode, post_type, privacy, status, created_at, updated_at)
            VALUES (\(uuid: author), \(bind: content), \(bind: mode), \(bind: type), 'public', 'posted', \(bind: at), \(bind: at))
            RETURNING id::text AS id
            """).first(decoding: R.self)!.id
        if !tags.isEmpty {
            try await t.raw("""
                INSERT INTO post_tags (post_id, tag, source) SELECT \(uuid: id), unnest(\(bind: tags)::text[]), 'user'
                ON CONFLICT (post_id, tag) DO NOTHING
                """).run()
        }
        return id
    }

    /// A reply hangs under the comment it answers, as `InteractionsController`
    /// places a reply to a top-level comment.
    private static func insertComment(_ text: String, post: String, author: String, replyTo: String?, at: Date,
                                      on t: any SQLDatabase) async throws -> String {
        struct R: Decodable { let id: String }
        return try await t.raw("""
            INSERT INTO comments (post_id, author_id, content, parent_comment_id, reply_to_comment_id, created_at)
            VALUES (\(uuid: post), \(uuid: author), \(bind: text), \(uuid: replyTo), \(uuid: replyTo), \(bind: at))
            RETURNING id::text AS id
            """).first(decoding: R.self)!.id
    }

    /// Spread over the day the fixture names, never in the future.
    private static func postTime(daysAgo: Int, rng: inout SeededGenerator) -> Date {
        let back = Double(daysAgo) * 86_400 + Double(Int.random(in: 1_800...43_200, using: &rng))
        return Date().addingTimeInterval(-back)
    }

    /// Follows, likes and comments on real accounts' latest public posts, with
    /// the notifications those would have sent.
    private static func touchRealAccounts(_ reals: [Real], ids: [String: String], modeOf: [String: String],
                                          on t: any SQLDatabase) async throws -> [String] {
        struct Target: Decodable { let id: String; let post_id: String? }
        func target(_ username: String, mode: String) async throws -> Target? {
            try await t.raw("""
                SELECT u.id::text AS id,
                       (SELECT p.id::text FROM posts p WHERE p.author_id = u.id AND p.mode = \(bind: mode)
                          AND p.status = 'posted' AND p.privacy = 'public' AND p.community_id IS NULL
                          AND p.content <> '' ORDER BY p.created_at DESC LIMIT 1) AS post_id
                FROM users u WHERE u.username = \(bind: username) AND u.deleted_at IS NULL
                """).first(decoding: Target.self)
        }
        struct Actor: Decodable { let display: String; let color: String? }
        func notify(_ type: String, to user: String, from username: String, post: String, entityType: String,
                    entityID: String, extra: [String: String] = [:]) async throws {
            let a = try await t.raw("""
                SELECT COALESCE(hobby_display_name, work_display_name, display_name) AS display, avatar_color AS color
                FROM users WHERE id = \(uuid: ids[username]!)
                """).first(decoding: Actor.self)!
            var payload: [String: Any] = ["fromUserId": ids[username]!, "fromDisplayName": a.display,
                                          "fromAvatarColor": a.color ?? NSNull(), "fromAvatarUrl": NSNull()]
            for (k, v) in extra { payload[k] = v }
            let json = String(data: try JSONSerialization.data(withJSONObject: payload), encoding: .utf8) ?? "{}"
            try await t.raw("""
                INSERT INTO user_notifications (user_id, type, actor_id, post_id, entity_type, entity_id, group_key, payload)
                VALUES (\(uuid: user), \(bind: type), \(uuid: ids[username]!), \(uuid: post), \(bind: entityType),
                        \(uuid: entityID), \(bind: "\(type):\(post)"), \(bind: json)::jsonb)
                """).run()
        }

        var follows = 0, likes = 0, comments = 0
        for real in reals {
            for pair in real.follow {
                let mode = modeOf[pair[0]]!
                guard let to = try await target(pair[1], mode: mode) else { continue }
                try await t.raw("""
                    INSERT INTO follows (follower_id, followee_id, mode) VALUES (\(uuid: ids[pair[0]]!), \(uuid: to.id), \(bind: mode))
                    ON CONFLICT DO NOTHING
                    """).run()
                follows += 1
            }
            for pair in real.like {
                guard let to = try await target(pair[1], mode: modeOf[pair[0]]!), let post = to.post_id else { continue }
                try await t.raw("INSERT INTO post_likes (post_id, user_id) VALUES (\(uuid: post), \(uuid: ids[pair[0]]!)) ON CONFLICT DO NOTHING").run()
                try await notify("post_liked", to: to.id, from: pair[0], post: post, entityType: "post", entityID: post)
                likes += 1
            }
            for triple in real.comment {
                guard let to = try await target(triple[1], mode: modeOf[triple[0]]!), let post = to.post_id else { continue }
                let commentID = try await insertComment(triple[2], post: post, author: ids[triple[0]]!, replyTo: nil, at: Date(), on: t)
                try await notify("post_commented", to: to.id, from: triple[0], post: post, entityType: "comment",
                                 entityID: commentID, extra: ["excerpt": String(triple[2].prefix(80)), "commentId": commentID])
                comments += 1
            }
        }
        return ["on real accounts: \(follows) follows, \(likes) likes, \(comments) comments"]
    }

    /// A stable, made-up 10-digit tax code for a demo company.
    static func demoTaxCode(_ name: String) -> String {
        var h: UInt64 = 1469598103934665603
        for b in name.lowercased().utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return String(format: "%010llu", h % 10_000_000_000)
    }

    /// "Ví Xanh" → "vixanh.vn", for a demo company without a website.
    static func slugDomain(_ name: String) -> String {
        name.folding(options: .diacriticInsensitive, locale: nil).lowercased().filter { $0.isLetter || $0.isNumber } + ".vn"
    }
}

/// SplitMix64, a fixed seed makes every re-seed draw the same likes and links.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

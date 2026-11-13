import Vapor
import SQLKit

/// `seed-demo communities [--commit]`: replaces every community and every
/// Marketplace listing with the six demo communities in
/// `Seeds/demo-communities.json` (members, posts, polls, events, comments,
/// likes and listings). Dry run by default; `--commit` backs up first.
///
/// Embeddings, AI tags and translations aren't written here: the server's
/// sweep jobs (`RUN_JOBS=1`) pick the new posts up.
extension SeedDemoCommand {
    struct CommunityFixture: Decodable { var communities: [SeedCommunity] }

    struct SeedCommunity: Decodable {
        var name: String
        var emoji: String
        var color: String
        var description: String
        var tags: [String]
        var approval: Bool?
        var admin: String
        var mods: [String]
        var members: [String]
        var posts: [SeedCommunityPost]
        var listings: [SeedListing]

        /// Admin first, then moderators, then members; no repeats.
        var everyone: [String] {
            var seen = Set<String>()
            return ([admin] + mods + members).filter { seen.insert($0).inserted }
        }
    }

    struct SeedCommunityPost: Decodable {
        var u: String
        var d: Int
        var t: String
        var likes: Int
        var pending: Bool?
        var poll: SeedPoll?
        var event: SeedEvent?
        var c: [SeedComment]?
    }
    struct SeedPoll: Decodable { var options: [String]; var endsInDays: Int }
    struct SeedEvent: Decodable { var title: String; var location: String; var startsInDays: Int; var hours: Int }
    struct SeedComment: Decodable { var u: String; var t: String; var r: [SeedComment]? }

    struct SeedListing: Decodable {
        var u: String
        var d: Int
        var title: String
        var caption: String
        var location: String
        var lat: Double
        var lng: Double
        var items: [SeedItem]
    }
    struct SeedItem: Decodable {
        var title: String
        var price: Int
        var condition: String
        var quantity: Int
        var photos: [String]
    }

    /// Checks the fixture against the promised shape (and the schema's
    /// CHECKs), so a bad edit fails before anything is written.
    static func communityFixtureProblem(_ f: CommunityFixture) -> String? {
        guard f.communities.count == 6 else { return "expected 6 communities" }
        for c in f.communities {
            let people = Set(c.everyone)
            guard (5...10).contains(people.count) else { return "\(c.name): \(people.count) members" }
            guard (2...3).contains(c.listings.count) else { return "\(c.name): \(c.listings.count) listings" }
            let perAuthor = Dictionary(grouping: c.posts, by: \.u).mapValues(\.count)
            if let (u, n) = perAuthor.first(where: { $0.value > 2 }) { return "\(c.name): \(u) has \(n) posts" }
            for p in c.posts {
                guard people.contains(p.u) else { return "\(c.name): \(p.u) posts but isn't a member" }
                for cm in p.c ?? [] {
                    for who in [cm.u] + (cm.r ?? []).map(\.u) where !people.contains(who) {
                        return "\(c.name): \(who) comments but isn't a member"
                    }
                }
                if let poll = p.poll, !(2...4).contains(poll.options.count) { return "\(c.name): poll needs 2–4 options" }
            }
            for l in c.listings {
                guard people.contains(l.u) else { return "\(c.name): seller \(l.u) isn't a member" }
                guard (1...5).contains(l.items.count) else { return "\(l.title): \(l.items.count) items" }
                for i in l.items {
                    guard ["new", "like_new", "good", "fair"].contains(i.condition) else { return "\(i.title): condition" }
                    guard (1...6).contains(i.photos.count), (1...999).contains(i.quantity), i.price >= 0 else {
                        return "\(i.title): photos, quantity or price out of range"
                    }
                }
            }
        }
        return nil
    }

    func seedCommunities(_ context: CommandContext, commit: Bool) async throws {
        let app = context.application
        let dir = app.directory.workingDirectory + "Seeds/"
        let fixture = try JSONDecoder().decode(CommunityFixture.self,
                                               from: Data(contentsOf: URL(fileURLWithPath: dir + "demo-communities.json")))
        if let problem = Self.communityFixtureProblem(fixture) {
            context.console.error("Fixture problem: \(problem)")
            return
        }

        // Everyone named must already exist (the demo people come from `seed`).
        struct U: Decodable { let id: String; let username: String }
        let names = Array(Set(fixture.communities.flatMap(\.everyone)))
        let found = try await app.db.sql().raw("""
            SELECT id::text AS id, username FROM users WHERE username = ANY(\(bind: names))
            """).all(decoding: U.self)
        let ids = Dictionary(uniqueKeysWithValues: found.map { ($0.username, $0.id) })
        let missing = names.filter { ids[$0] == nil }.sorted()
        guard missing.isEmpty else {
            context.console.error("Missing users (run `seed-demo seed` first?): \(missing.joined(separator: ", "))")
            return
        }

        try copyPhotos(fixture, context)
        if commit { try backUp(context) }

        do {
            let lines = try await app.db.withTransaction { t -> [String] in
                var lines = try await Self.wipeCommunitiesAndListings(on: t)
                var rng = SeededGenerator(seed: 20261113)
                for c in fixture.communities {
                    lines.append(try await Self.insertCommunity(c, ids: ids, rng: &rng, on: t))
                }
                lines += try await Self.recountCounters(on: t)
                if !commit { throw DryRun(lines: lines) }
                return lines
            }
            lines.forEach { context.console.info($0) }
            context.console.info("Communities seeded. Restart the server so the sweep jobs embed and translate the new posts.")
        } catch let dry as DryRun {
            dry.lines.forEach { context.console.info($0) }
            context.console.warning("Dry run, rolled back. Re-run with --commit to back up and replace.")
        }
    }

    /// The photos live in `Seeds/marketplace-photos/` (uploads aren't in git);
    /// copied into the served uploads folder, keeping any already there.
    private func copyPhotos(_ f: CommunityFixture, _ context: CommandContext) throws {
        let app = context.application
        let src = app.directory.workingDirectory + "Seeds/marketplace-photos/"
        let dst = app.directory.workingDirectory + "../backend/uploads/"
        let fm = FileManager.default
        let names = Set(f.communities.flatMap { $0.listings.flatMap { $0.items.flatMap(\.photos) } })
        for name in names {
            for file in ["\(name).jpg", "\(name)_t.jpg"] {
                guard fm.fileExists(atPath: src + file) else {
                    throw Abort(.internalServerError, reason: "Missing seed photo \(file)")
                }
                if !fm.fileExists(atPath: dst + file) { try fm.copyItem(atPath: src + file, toPath: dst + file) }
            }
        }
    }

    // MARK: - Wipe

    private struct Count: Decodable { let n: Int }

    /// Every listing post (re-up copies too, which no `listing_posts` row
    /// points at), then every community's posts, then the communities. Posts
    /// go first because `posts.community_id` is ON DELETE SET NULL.
    static func wipeCommunitiesAndListings(on t: any SQLDatabase) async throws -> [String] {
        func n(_ sql: SQLQueryString) async throws -> Int { try await t.raw(sql).first(decoding: Count.self)?.n ?? 0 }
        let orphanedShares = try await n("""
            SELECT COUNT(*)::int AS n FROM messages m JOIN posts p ON p.id = m.shared_post_id
            WHERE p.post_type = 'listing' OR p.community_id IS NOT NULL
            """)
        let listings = try await n("WITH d AS (DELETE FROM posts WHERE post_type = 'listing' RETURNING 1) SELECT COUNT(*)::int AS n FROM d")
        let posts = try await n("WITH d AS (DELETE FROM posts WHERE community_id IS NOT NULL RETURNING 1) SELECT COUNT(*)::int AS n FROM d")
        let communities = try await n("WITH d AS (DELETE FROM communities RETURNING 1) SELECT COUNT(*)::int AS n FROM d")
        return [
            "Deleted \(listings) listing posts, \(posts) community posts, \(communities) communities.",
            "Chat messages that shared one of them (now \"post unavailable\"): \(orphanedShares).",
        ]
    }

    // MARK: - Seed

    private struct ID: Decodable { let id: String }

    static func insertCommunity(_ c: SeedCommunity, ids: [String: String], rng: inout SeededGenerator,
                                on t: any SQLDatabase) async throws -> String {
        let created = Date().addingTimeInterval(-24 * 86_400)
        let communityID = try await t.raw("""
            INSERT INTO communities (name, description, description_format, type, privacy, icon_emoji, cover_color,
                                     require_post_approval, created_by, created_at, updated_at)
            VALUES (\(bind: c.name), \(bind: c.description), 'markdown', 'fandom', 'public', \(bind: c.emoji), \(bind: c.color),
                    \(bind: c.approval ?? false), \(uuid: ids[c.admin]!), \(bind: created), \(bind: created))
            RETURNING id::text AS id
            """).first(decoding: ID.self)!.id
        for tag in c.tags {
            try await t.raw("INSERT INTO community_tags (community_id, tag) VALUES (\(uuid: communityID), \(bind: tag)) ON CONFLICT DO NOTHING").run()
        }
        let members = c.everyone
        for (i, u) in members.enumerated() {
            let role = u == c.admin ? "admin" : c.mods.contains(u) ? "moderator" : "member"
            let joined = created.addingTimeInterval(Double(i) * 3_600 * 7)
            try await t.raw("""
                INSERT INTO community_members (community_id, user_id, role, joined_at)
                VALUES (\(uuid: communityID), \(uuid: ids[u]!), \(bind: role), \(bind: joined))
                """).run()
        }

        var polls = 0, events = 0, comments = 0
        for p in c.posts {
            let at = Date().addingTimeInterval(-(Double(p.d) * 86_400 + Double(Int.random(in: 3_600...36_000, using: &rng))))
            let type = p.poll != nil ? "poll" : p.event != nil ? "event" : "text"
            let (content, hashtags) = splitHashtags(p.t)
            let postID = try await t.raw("""
                INSERT INTO posts (author_id, content, mode, post_type, privacy, status, community_id, community_audience,
                                   created_at, updated_at)
                VALUES (\(uuid: ids[p.u]!), \(bind: content), 'hobby', \(bind: type), 'public',
                        \(bind: p.pending == true ? "pending" : "posted")::post_status, \(uuid: communityID), 'public',
                        \(bind: at), \(bind: at))
                RETURNING id::text AS id
                """).first(decoding: ID.self)!.id
            if !hashtags.isEmpty {
                try await t.raw("""
                    INSERT INTO post_tags (post_id, tag, source) SELECT \(uuid: postID), unnest(\(bind: hashtags)::text[]), 'user'
                    ON CONFLICT (post_id, tag) DO NOTHING
                    """).run()
            }
            let others = members.filter { $0 != p.u }

            if let poll = p.poll {
                let endDay = Date().addingTimeInterval(Double(poll.endsInDays) * 86_400)
                let ends = ISO8601DateFormatter().string(from: Calendar.current.date(bySettingHour: 21, minute: 0, second: 0, of: endDay)!)
                try await PollStore.createWithOptions(postID: postID, options: poll.options, endsAt: ends, on: t)
                let options = try await t.raw("SELECT id::text AS id FROM poll_options WHERE post_id = \(uuid: postID) ORDER BY position")
                    .all(decoding: ID.self)
                for voter in others.shuffled(using: &rng).prefix(max(2, others.count - 1)) {
                    let option = options[Int.random(in: 0..<options.count, using: &rng)].id
                    try await t.raw("""
                        INSERT INTO poll_votes (poll_option_id, user_id, voted_at)
                        VALUES (\(uuid: option), \(uuid: ids[voter]!), \(bind: at.addingTimeInterval(3_600)))
                        """).run()
                }
                polls += 1
            }
            if let e = p.event {
                let start = Calendar.current.date(bySettingHour: 18, minute: 0, second: 0,
                                                  of: Date().addingTimeInterval(Double(e.startsInDays) * 86_400))!
                let f = ISO8601DateFormatter()
                try await EventStore.create(postID: postID, title: e.title, location: e.location, startsAt: f.string(from: start),
                                            endsAt: f.string(from: start.addingTimeInterval(Double(e.hours) * 3_600)), on: t)
                let eventID = try await t.raw("SELECT id::text AS id FROM community_events WHERE post_id = \(uuid: postID)")
                    .first(decoding: ID.self)!.id
                for who in others.shuffled(using: &rng).prefix(max(2, others.count - 2)) {
                    let status = ["going", "going", "going", "maybe", "not_going"][Int.random(in: 0..<5, using: &rng)]
                    try await t.raw("""
                        INSERT INTO event_rsvps (event_id, user_id, status, rsvp_at)
                        VALUES (\(uuid: eventID), \(uuid: ids[who]!), \(bind: status), \(bind: at.addingTimeInterval(7_200)))
                        """).run()
                }
                events += 1
            }

            // A post waiting for approval has no engagement yet.
            guard p.pending != true else { continue }
            for liker in others.shuffled(using: &rng).prefix(min(p.likes, others.count)) {
                let likedAt = at.addingTimeInterval(Double(Int.random(in: 600...20_000, using: &rng)))
                try await t.raw("""
                    INSERT INTO post_likes (post_id, user_id, created_at)
                    VALUES (\(uuid: postID), \(uuid: ids[liker]!), \(bind: likedAt))
                    """).run()
            }
            var when = at
            for cm in p.c ?? [] {
                when = when.addingTimeInterval(Double(Int.random(in: 900...10_800, using: &rng)))
                let top = try await insertCommunityComment(cm.t, post: postID, author: ids[cm.u]!, replyTo: nil, at: when, on: t)
                comments += 1
                try await likeComment(top, by: others.filter { $0 != cm.u }, ids: ids, rng: &rng, on: t)
                for r in cm.r ?? [] {
                    when = when.addingTimeInterval(Double(Int.random(in: 600...7_200, using: &rng)))
                    _ = try await insertCommunityComment(r.t, post: postID, author: ids[r.u]!, replyTo: top, at: when, on: t)
                    comments += 1
                }
            }
        }

        var items = 0
        for l in c.listings {
            items += l.items.count
            try await insertListing(l, communityID: communityID, sellerID: ids[l.u]!, rng: &rng, on: t)
        }
        return "\(c.name): \(members.count) members, \(c.posts.count) posts (\(polls) poll, \(events) event), "
            + "\(comments) comments, \(c.listings.count) listings (\(items) items)."
    }

    /// A reply hangs under the comment it answers, as `seed` places them.
    private static func insertCommunityComment(_ text: String, post: String, author: String, replyTo: String?, at: Date,
                                               on t: any SQLDatabase) async throws -> String {
        try await t.raw("""
            INSERT INTO comments (post_id, author_id, content, parent_comment_id, reply_to_comment_id, created_at)
            VALUES (\(uuid: post), \(uuid: author), \(bind: text), \(uuid: replyTo), \(uuid: replyTo), \(bind: at))
            RETURNING id::text AS id
            """).first(decoding: ID.self)!.id
    }

    /// 0–2 likes on a comment.
    private static func likeComment(_ commentID: String, by pool: [String], ids: [String: String],
                                    rng: inout SeededGenerator, on t: any SQLDatabase) async throws {
        for u in pool.shuffled(using: &rng).prefix(Int.random(in: 0...2, using: &rng)) {
            try await t.raw("INSERT INTO comment_likes (comment_id, user_id) VALUES (\(uuid: commentID), \(uuid: ids[u]!)) ON CONFLICT DO NOTHING").run()
        }
    }

    /// The listing post, its summary row, its items and its community link,
    /// in the shape `ListingStore` writes; `syncSummary` then fills the
    /// listing's price, condition and cover photos from the items.
    private static func insertListing(_ l: SeedListing, communityID: String, sellerID: String,
                                      rng: inout SeededGenerator, on t: any SQLDatabase) async throws {
        let at = Date().addingTimeInterval(-(Double(l.d) * 86_400 + Double(Int.random(in: 3_600...30_000, using: &rng))))
        let postID = try await t.raw("""
            INSERT INTO posts (author_id, content, mode, post_type, privacy, status, created_at, updated_at)
            VALUES (\(uuid: sellerID), \(bind: l.caption), 'hobby', 'listing', 'public', 'posted', \(bind: at), \(bind: at))
            RETURNING id::text AS id
            """).first(decoding: ID.self)!.id
        let listingID = try await t.raw("""
            INSERT INTO listing_posts (post_id, title, price, condition, location, latitude, longitude, created_at, updated_at)
            VALUES (\(uuid: postID), \(bind: l.title), \(bind: l.items.map(\.price).min() ?? 0), \(bind: l.items[0].condition),
                    \(bind: l.location), \(bind: l.lat), \(bind: l.lng), \(bind: at), \(bind: at))
            RETURNING id::text AS id
            """).first(decoding: ID.self)!.id
        for (position, item) in l.items.enumerated() {
            let urls = item.photos.map { "/uploads/\($0).jpg" }
            try await t.raw("""
                INSERT INTO listing_items (listing_id, position, title, price, condition, quantity, image_urls)
                VALUES (\(uuid: listingID), \(bind: position), \(bind: item.title), \(bind: item.price),
                        \(bind: item.condition), \(bind: item.quantity), \(bind: urls))
                """).run()
        }
        try await t.raw("""
            INSERT INTO listing_communities (listing_id, community_id, status) VALUES (\(uuid: listingID), \(uuid: communityID), 'posted')
            """).run()
        try await ListingStore.syncSummary(listingID: listingID, on: t)
    }
}

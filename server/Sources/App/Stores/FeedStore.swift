import Vapor
import SQLKit

/// The personalized newsfeed.
/// Taste vector built in Swift from `user_embedding_chunks` (populated by the
/// embed worker), then a keyset-paginated blended-ranking CTE.
enum FeedStore {
    static let wSemantic = 0.50, wRecency = 0.35, wEngagement = 0.15
    static let discoveryThreshold = 0.65
    static let recencyTauHours = 72.0
    /// The feed scores the newest this-many posts from the last
    /// `candidateDays` (plus your connections', follows' and peers'), not
    /// every post in the mode.
    static let maxCandidates = 400, candidateDays = 60

    // MARK: Several interests (phase D)

    /// Up to this many taste clusters from what you do, plus your profile as
    /// one more: a post scores by the interest it matches best, so J-pop and
    /// iOS each find their own posts instead of a blurry average.
    static let maxInterests = 4, clusterRounds = 10
    /// How far your skips and "Not interested" pull every interest away.
    static let negativePull = 0.3

    // MARK: Closeness to each author (phase D)

    /// Replaces the flat connection bonus: up to this much for the people
    /// you're closest to.
    static let closenessBoost = 0.25
    /// Being connected / following counts this much of it; the rest comes
    /// from how much you've liked, commented on, read and messaged them in
    /// the last 60 days (half of it at `interactionHalf` weighted actions).
    static let connectionBase = 0.4, followBase = 0.2, interactionShare = 0.6, interactionHalf = 5.0
    static let closenessDays = 60
    /// A little lift for authors you've never met, so new people and topics
    /// keep turning up (exploration).
    static let newAuthorBoost = 0.05

    // MARK: People like you (phase E)

    /// People who liked, saved, commented on or read the same posts as you in
    /// the last 30 days (the 50 with most in common). What they engaged with
    /// that you haven't is lifted, by how much they share your taste.
    static let peerDays = 30, maxPeers = 50
    static let peerBoost = 0.15, peerHalf = 3.0
    /// Enough overlap to enter the personalised pass on its own, even when
    /// the post doesn't look like your interests.
    static let peerStrictMin = 2.0

    /// 0…`peerBoost` from how much your peers engaged with a post.
    static func peerLift(_ shared: Double) -> Double {
        let used = max(shared, 0)
        return peerBoost * used / (used + peerHalf)
    }

    // MARK: Cold start (phase E)

    /// With no profile or activity yet, a new account still gets local and
    /// readable posts first: by authors in the same city, and in a language
    /// you speak.
    static let nearbyBoost = 0.1, languageBoost = 0.05

    /// "Ho Chi Minh City" and "ho chi minh" are the same place.
    static func normalizedPlace(_ place: String?) -> String? {
        guard var p = place?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !p.isEmpty else { return nil }
        if p.hasSuffix(" city") { p = String(p.dropLast(5)).trimmingCharacters(in: .whitespaces) }
        return p.isEmpty ? nil : p
    }

    /// Profile languages ("Vietnamese", "English") as the codes posts carry.
    static func languageCodes(_ names: [String]) -> [String] {
        let map = ["vietnamese": "vi", "tiếng việt": "vi", "english": "en", "tiếng anh": "en"]
        return Array(Set(names.compactMap { map[$0.lowercased().trimmingCharacters(in: .whitespaces)] })).sorted()
    }

    /// 0…1 closeness to an author.
    static func closeness(isConnection: Bool, isFollowing: Bool, interactions: Double) -> Double {
        let used = max(interactions, 0)
        return min(1, (isConnection ? connectionBase : 0) + (isFollowing ? followBase : 0)
            + interactionShare * used / (used + interactionHalf))
    }

    /// Splits your liked/read posts into up to `maxK` interests (weighted,
    /// deterministic k-means on cosine similarity). Seeds are the heaviest
    /// post, then each time the post least like the seeds so far.
    static func clusterTaste(_ vectors: [[Double]], weights: [Double], maxK: Int) -> [[Double]] {
        guard let dim = vectors.first?.count, dim > 0 else { return [] }
        let weights = weights.count == vectors.count ? weights : Array(repeating: 1, count: vectors.count)
        let points = vectors.map(normalize)
        let idx = points.indices.filter { points[$0].count == dim }
        guard !idx.isEmpty else { return [] }
        // Runs on every feed request: each similarity is computed once (not
        // per comparison) over raw buffers. Same sums in the same order, so
        // the result is bit-identical to the plain version.
        func cos(_ a: [Double], _ b: [Double]) -> Double {
            a.withUnsafeBufferPointer { a in
                b.withUnsafeBufferPointer { b in
                    var s = 0.0
                    for d in 0..<min(a.count, b.count) { s += a[d] * b[d] }
                    return s
                }
            }
        }
        let k = min(maxK, max(1, idx.count / 3))
        var seeds = [idx.max { weights[$0] < weights[$1] }!]
        // Each point's similarity to its nearest seed so far.
        var nearest = [Double](repeating: -.infinity, count: points.count)
        while seeds.count < k {
            for i in idx { nearest[i] = max(nearest[i], cos(points[i], points[seeds.last!])) }
            let rest = idx.filter { !seeds.contains($0) }
            guard let next = rest.min(by: { nearest[$0] < nearest[$1] }) else { break }
            seeds.append(next)
        }
        var centroids = seeds.map { points[$0] }
        for _ in 0..<clusterRounds {
            var sums = [[Double]](repeating: [Double](repeating: 0, count: dim), count: centroids.count)
            var used = [Bool](repeating: false, count: centroids.count)
            for i in idx {
                let sims = centroids.map { cos(points[i], $0) }
                let best = sims.indices.max { sims[$0] < sims[$1] }!
                let w = weights[i]
                points[i].withUnsafeBufferPointer { p in
                    sums[best].withUnsafeMutableBufferPointer { s in
                        for d in 0..<dim { s[d] += w * p[d] }
                    }
                }
                used[best] = true
            }
            let updated = centroids.indices.map { used[$0] ? normalize(sums[$0]) : centroids[$0] }
            if updated == centroids { break }
            centroids = updated
        }
        return centroids
    }

    /// Reorders one page so the same author never shows twice in a row and,
    /// within each run of 10, no author has more than 2 posts or topic more
    /// than 3, falling back step by step when nothing else is left. Nothing
    /// is dropped, so paging is unaffected.
    static func spread<T>(_ items: [T], author: (T) -> String, topic: (T) -> String?) -> [T] {
        var remaining = items
        var out: [T] = []
        while !remaining.isEmpty {
            let block = out[(out.count / 10) * 10..<out.count]
            let last = out.last.map(author)
            func authorCount(_ a: String) -> Int { block.filter { author($0) == a }.count }
            func topicCount(_ t: String) -> Int { block.filter { topic($0) == t }.count }
            let pick = remaining.firstIndex { item in
                author(item) != last && authorCount(author(item)) < 2
                    && (topic(item).map { topicCount($0) < 3 } ?? true)
            } ?? remaining.firstIndex { author($0) != last } ?? 0
            out.append(remaining.remove(at: pick))
        }
        return out
    }

    // MARK: Behaviour (FEED_RANKING_REVIEW.md, phase B)

    /// How much each kind of action says about your taste. A fast skip
    /// (scrolled past in under a second, never lingered) counts against.
    enum Action {
        static let like = 1.0, comment = 2.0, save = 2.0, share = 3.0
        static let open = 1.0, longRead = 1.5, fastSkip = -0.5
        static let showMore = 2.0, notInterested = -1.5
    }
    /// An action counts half as much after this many days.
    static let actionHalfLifeDays = 14.0
    /// Actions older than this are ignored; at most this many posts are used.
    static let actionWindowDays = 60, maxTastePosts = 200
    /// On screen at least this long = read, not just passed.
    static let longReadMs = 8_000

    /// A post you've already seen sinks: hard if first seen in the last
    /// 3 days (and left out of the personalised pass), gently if earlier.
    static let seenRecentHours = 72.0
    static let seenRecentPenalty = 0.5, seenOlderPenalty = 0.2

    /// Engagement per viewer, not lifetime totals: a fresh post doing well
    /// for how few have seen it can beat an old one with more likes.
    /// `ratePrior` stands in for viewers a post hasn't had yet; `rateHalf` is
    /// the rate that scores 0.5.
    static let ratePrior = 20.0, rateHalf = 0.25

    // MARK: "Not interested" / "Show more like this" (phase C)

    static let feedbackKinds: Set<String> = ["less", "more"]
    /// How long feedback keeps working.
    static let feedbackDays = 30
    /// Cosine distance under which a post counts as "like" the one you
    /// gave feedback on (similarity ≥ 0.8).
    static let similarDistance = 0.2
    static let lessSimilarPenalty = 0.4, lessAuthorPenalty = 0.3
    static let moreSimilarBoost = 0.2, moreAuthorBoost = 0.15

    /// What your feedback adds to a post's score.
    static func feedbackAdjustment(lessSimilar: Bool, lessAuthor: Bool, moreSimilar: Bool, moreAuthor: Bool) -> Double {
        (moreSimilar ? moreSimilarBoost : 0) + (moreAuthor ? moreAuthorBoost : 0)
            - (lessSimilar ? lessSimilarPenalty : 0) - (lessAuthor ? lessAuthorPenalty : 0)
    }

    /// An action's weight after `ageDays`.
    static func decayed(_ weight: Double, ageDays: Double) -> Double {
        weight * pow(0.5, max(ageDays, 0) / actionHalfLifeDays)
    }

    /// 0…1 engagement from interactions per viewer.
    static func engagementScore(likes: Int, comments: Int, shares: Int, viewers: Int) -> Double {
        let rate = Double(likes + 2 * comments + 3 * shares) / (Double(max(viewers, 0)) + ratePrior)
        return rate / (rate + rateHalf)
    }

    /// How far a post sinks, by when you first saw it (nil = never).
    static func seenPenalty(firstSeenHoursAgo: Double?) -> Double {
        guard let h = firstSeenHoursAgo else { return 0 }
        return h < seenRecentHours ? seenRecentPenalty : seenOlderPenalty
    }

    /// `asOf` pins the "now" used for every page's `recency` computation to
    /// whenever the *first* page of a pagination sequence was fetched. See
    /// `getRecommendedFeed`'s use of it below for why.
    struct Cursor: Codable { var score: Double; var id: String; var relaxed: Bool?; var asOf: Date }

    static func encodeCursor(_ score: Double, _ id: String, relaxed: Bool, asOf: Date) -> String {
        let c = Cursor(score: score, id: id, relaxed: relaxed ? true : nil, asOf: asOf)
        return (try? JSONEncoder().encode(c)).map { Data($0).base64EncodedString() } ?? ""
    }
    static func decodeCursor(_ s: String) -> Cursor? {
        guard let data = Data(base64Encoded: s), let c = try? JSONDecoder().decode(Cursor.self, from: data) else { return nil }
        return c
    }

    static func parseVec(_ text: String) -> [Double] {
        text.dropFirst().dropLast().split(separator: ",").map { Double($0) ?? 0 }
    }
    static func meanVec(_ vs: [[Double]]) -> [Double] {
        guard let dim = vs.first?.count, dim > 0 else { return [] }
        var out = [Double](repeating: 0, count: dim)
        for v in vs { for i in 0..<dim { out[i] += v[i] } }
        for i in 0..<dim { out[i] /= Double(vs.count) }
        return out
    }
    static func normalize(_ v: [Double]) -> [Double] {
        let n = sqrt(v.reduce(0) { $0 + $1 * $1 })
        return n == 0 ? v : v.map { $0 / n }
    }
    static func toVectorLiteral(_ v: [Double]) -> String { "[" + v.map { String($0) }.joined(separator: ",") + "]" }

    /// Your interests: your profile, plus up to `maxInterests` clusters of
    /// what you engage with, each pulled away from what you skip or said
    /// "Not interested" to. Nil when there's nothing to go on.
    static func buildTasteVectors(_ userID: String, on db: any SQLDatabase) async throws -> [[Double]]? {
        struct V: Decodable { let vec: String }
        let profile = try await db.raw("SELECT embedding::text AS vec FROM user_embedding_chunks WHERE user_id = \(uuid: userID) AND source_type = 'user_profile'")
            .all(decoding: V.self).map { parseVec($0.vec) }
        let signals = try await behaviorSignals(userID, on: db)
        let positive = signals.filter { $0.weight > 0 }
        let negative = signals.filter { $0.weight < 0 }
        var tastes: [[Double]] = []
        if !profile.isEmpty { tastes.append(normalize(meanVec(profile))) }
        var interests = clusterTaste(positive.map(\.vec), weights: positive.map(\.weight), maxK: maxInterests)
        if !negative.isEmpty, let dim = interests.first?.count {
            var away = [Double](repeating: 0, count: dim)
            for n in negative where n.vec.count == dim { for i in 0..<dim { away[i] += -n.weight * n.vec[i] } }
            let pull = normalize(away)
            interests = interests.map { c in normalize(c.indices.map { c[$0] - negativePull * pull[$0] }) }
        }
        tastes += interests
        if tastes.isEmpty {
            // Brand new: start from the interests picked at sign-up. Posts
            // tagged with or mentioning them, before any profile embedding.
            tastes = clusterTaste(try await interestPickVectors(userID, on: db), weights: [], maxK: maxInterests)
        }
        return tastes.isEmpty ? nil : tastes
    }

    /// Embeddings of recent posts about the interests you picked (a tag equal
    /// to one, or its name in the text).
    static func interestPickVectors(_ userID: String, on db: any SQLDatabase) async throws -> [[Double]] {
        struct V: Decodable { let vec: String }
        return try await db.raw("""
            SELECT c.embedding::text AS vec
            FROM posts p JOIN user_embedding_chunks c ON c.source_type = 'post' AND c.source_id = p.id
            WHERE p.status = 'posted' AND EXISTS (
              SELECT 1 FROM user_interests ui WHERE ui.user_id = \(uuid: userID) AND (
                EXISTS (SELECT 1 FROM post_tags pt WHERE pt.post_id = p.id AND lower(pt.tag) = lower(ui.interest))
                OR position(lower(ui.interest) IN lower(COALESCE(p.content, ''))) > 0))
            ORDER BY p.created_at DESC LIMIT 60
            """).all(decoding: V.self).map { parseVec($0.vec) }
    }

    /// What you do, as (post embedding, weight): every post you liked,
    /// commented on, saved, shared, opened or read for a while, and. With a
    /// negative weight, ones you skipped straight past or said "Not
    /// interested" to; each weighted by the action and how recent it was.
    static func behaviorSignals(_ userID: String, on db: any SQLDatabase) async throws -> [(vec: [Double], weight: Double)] {
        struct Row: Decodable { let vec: String; let weight: Double }
        let since: SQLQueryString = "NOW() - INTERVAL '\(unsafeRaw: String(actionWindowDays)) days'"
        let rows = try await db.raw("""
            WITH ev AS (
              SELECT post_id, \(unsafeRaw: String(Action.like)) AS w, created_at AS at
                FROM post_likes WHERE user_id = \(uuid: userID) AND created_at > \(since)
              UNION ALL SELECT post_id, \(unsafeRaw: String(Action.comment)), created_at
                FROM comments WHERE author_id = \(uuid: userID) AND status <> 'deleted' AND created_at > \(since)
              UNION ALL SELECT post_id, \(unsafeRaw: String(Action.save)), created_at
                FROM saved_posts WHERE user_id = \(uuid: userID) AND created_at > \(since)
              UNION ALL SELECT shared_post_id, \(unsafeRaw: String(Action.share)), created_at
                FROM posts WHERE author_id = \(uuid: userID) AND shared_post_id IS NOT NULL
                  AND status = 'posted' AND created_at > \(since)
              UNION ALL SELECT post_id, \(unsafeRaw: String(Action.open)), opened_at
                FROM post_impressions WHERE user_id = \(uuid: userID) AND opened_at > \(since)
              UNION ALL SELECT post_id, \(unsafeRaw: String(Action.longRead)), last_seen_at
                FROM post_impressions WHERE user_id = \(uuid: userID) AND last_seen_at > \(since)
                  AND view_ms >= \(unsafeRaw: String(longReadMs))
              UNION ALL SELECT post_id, \(unsafeRaw: String(Action.fastSkip)), last_seen_at
                FROM post_impressions WHERE user_id = \(uuid: userID) AND last_seen_at > \(since)
                  AND fast_skips = views AND views > 0 AND opened_at IS NULL
              UNION ALL SELECT post_id,
                  CASE WHEN kind = 'more' THEN \(unsafeRaw: String(Action.showMore))
                       ELSE \(unsafeRaw: String(Action.notInterested)) END, created_at
                FROM post_feedback WHERE user_id = \(uuid: userID) AND created_at > \(since)
            )
            SELECT c.embedding::text AS vec,
                   SUM(ev.w * POWER(0.5, EXTRACT(EPOCH FROM (NOW() - ev.at)) / 86400.0
                       / \(unsafeRaw: String(actionHalfLifeDays))))::float AS weight
            FROM ev JOIN user_embedding_chunks c ON c.source_type = 'post' AND c.source_id = ev.post_id
            GROUP BY c.id, c.embedding
            ORDER BY MAX(ev.at) DESC LIMIT \(bind: maxTastePosts)
            """).all(decoding: Row.self)
        return rows.map { (parseVec($0.vec), $0.weight) }.filter { $0.weight != 0 }
    }

    /// `weight` when the candidate post (`p`, embedding `c`) is like, or by
    /// the author of. A post you gave `kind` feedback on in the last 30 days.
    /// Feedback newer than the first page (`asOf`) waits for the next refresh,
    /// so paging stays stable.
    private static func feedbackTerm(kind: String, similar: Bool, userID: String, asOf: Date,
                                     weight: Double) -> SQLQueryString {
        let match: SQLQueryString = similar
            ? "JOIN user_embedding_chunks fc ON fc.source_type = 'post' AND fc.source_id = f.post_id WHERE (c.embedding <=> fc.embedding) <= \(unsafeRaw: String(similarDistance)) AND"
            : "WHERE f.author_id = p.author_id AND"
        return """
            (CASE WHEN EXISTS (SELECT 1 FROM post_feedback f \(match)
              f.user_id = \(uuid: userID) AND f.kind = \(bind: kind) AND f.created_at <= \(bind: asOf)
              AND f.created_at > \(bind: asOf) - INTERVAL '\(unsafeRaw: String(feedbackDays)) days')
            THEN \(unsafeRaw: String(weight)) ELSE 0 END)
            """
    }

    struct FeedRow: Decodable {
        var id: String
        var content: String?
        var content_format: String?
        var mode: String
        var privacy: String
        var image_url: String?
        var image_urls: [String]?
        var image_alts: [String]?
        var lang: String?
        var translated_text: String?
        var article_title: String?
        var link_url: String?
        var like_count: Int
        var comment_count: Int
        var share_count: Int
        var created_at: Date
        var edited_at: Date?
        var post_type: String
        var is_pinned: Bool
        var pinned_at: Date?
        var shared_post_id: String?
        var is_liked: Bool
        var is_connection: Bool
        var semantic: Double
        var recency: Double
        var engagement: Double
        var shared_post: String?
        var author: String
        var tags: String
        var event_data: String?
        var poll_data: String?
        var job_data: String?
        var listing_data: String?
        var community: String?
        var shared_community: String?
        var score: Double
    }

    static func getRecommendedFeed(userID: String, mode: String, cursor: String?, limit: Int, on db: any SQLDatabase)
        async throws -> (posts: [FeedPostObject], nextCursor: String?)
    {
        let tastes = try await buildTasteVectors(userID, on: db)
        let hasTaste = tastes != nil
        struct Viewer: Decodable { let location: String?; let languages: [String]? }
        let viewer = try await db.raw("SELECT location, languages FROM users WHERE id = \(uuid: userID)")
            .first(decoding: Viewer.self)
        let place = normalizedPlace(viewer?.location)
        let langs = languageCodes(viewer?.languages ?? [])
        let decoded = cursor.flatMap(decodeCursor)
        var relaxed = decoded?.relaxed == true
        // Pin "now" for the whole pagination sequence, not a fresh `NOW()`
        // per page: `recency` (and therefore `score`) is a continuously
        // time-decaying value, and two different posts decay at different
        // absolute rates (a newer, higher-recency post's score falls faster
        // in absolute terms than an older one's, even at the same tau), so
        // recomputing against a fresh clock on every request lets a post
        // that was correctly ranked just above the keyset cursor boundary
        // drift to just below it moments later, and get returned again on a
        // later page. Freezing the reference instant at the first page and
        // carrying it through the cursor makes every page's ranking (and the
        // keyset comparison against it) self-consistent.
        let asOf = decoded?.asOf ?? Date()

        func run(relaxed: Bool) async throws -> [FeedRow] {
            // COALESCE to 0 (not left NULL) for a post with no chunk yet. A
            // bare NULL would poison the whole weighted `score` sum below via
            // SQL's NULL-propagation, silently dropping the post from ranking
            // entirely rather than just scoring its semantic term as "unknown".
            // The best match among your interests (see buildTasteVectors).
            var semanticExpr: SQLQueryString = "0::float"
            if let tastes {
                semanticExpr = "GREATEST("
                for (i, t) in tastes.enumerated() {
                    if i > 0 { semanticExpr = semanticExpr + ", " }
                    semanticExpr = semanticExpr + "COALESCE((1 - (c.embedding <=> \(bind: toVectorLiteral(t))::vector))::float, 0)"
                }
                semanticExpr = semanticExpr + ")"
            }
            // How much you've engaged with each author lately (see closeness),
            // as of the first page so paging stays stable.
            let closeSince: SQLQueryString = "\(bind: asOf) - INTERVAL '\(unsafeRaw: String(closenessDays)) days'"
            let peerSince: SQLQueryString = "\(bind: asOf) - INTERVAL '\(unsafeRaw: String(peerDays)) days'"
            // Cold start only: same city / a language you speak.
            var coldStart: SQLQueryString = "0"
            if !hasTaste {
                if let place {
                    coldStart = coldStart + " + CASE WHEN lower(regexp_replace(trim(COALESCE(author_location, '')), '\\s+city$', '', 'i')) = \(bind: place) THEN \(unsafeRaw: String(nearbyBoost)) ELSE 0 END"
                }
                if !langs.isEmpty {
                    coldStart = coldStart + " + CASE WHEN lang = ANY(\(bind: langs)::text[]) THEN \(unsafeRaw: String(languageBoost)) ELSE 0 END"
                }
            }
            var q: SQLQueryString = """
            WITH pos AS (
              SELECT user_id AS uid, post_id FROM post_likes WHERE created_at > \(peerSince) AND created_at <= \(bind: asOf)
              UNION SELECT user_id, post_id FROM saved_posts WHERE created_at > \(peerSince) AND created_at <= \(bind: asOf)
              UNION SELECT author_id, post_id FROM comments WHERE status <> 'deleted'
                AND created_at > \(peerSince) AND created_at <= \(bind: asOf)
              UNION SELECT user_id, post_id FROM post_impressions
                WHERE (view_ms >= \(unsafeRaw: String(longReadMs)) OR opened_at IS NOT NULL)
                  AND first_seen_at > \(peerSince) AND first_seen_at <= \(bind: asOf)
            ),
            mine AS (SELECT post_id FROM pos WHERE uid = \(uuid: userID)),
            peers AS (
              SELECT o.uid, COUNT(*)::float AS shared FROM pos o JOIN mine m ON m.post_id = o.post_id
              WHERE o.uid <> \(uuid: userID) GROUP BY o.uid ORDER BY shared DESC LIMIT \(bind: maxPeers)
            ),
            cf AS (
              SELECT o.post_id, SUM(pe.shared)::float AS s FROM pos o JOIN peers pe ON pe.uid = o.uid
              WHERE o.post_id NOT IN (SELECT post_id FROM mine) GROUP BY o.post_id
            ),
            aff AS (
              SELECT x.author_id, SUM(x.w)::float AS raw FROM (
                SELECT p2.author_id, \(unsafeRaw: String(Action.like)) AS w FROM post_likes l JOIN posts p2 ON p2.id = l.post_id
                  WHERE l.user_id = \(uuid: userID) AND l.created_at > \(closeSince) AND l.created_at <= \(bind: asOf)
                UNION ALL SELECT p2.author_id, \(unsafeRaw: String(Action.comment)) FROM comments cm JOIN posts p2 ON p2.id = cm.post_id
                  WHERE cm.author_id = \(uuid: userID) AND cm.status <> 'deleted'
                    AND cm.created_at > \(closeSince) AND cm.created_at <= \(bind: asOf)
                UNION ALL SELECT p2.author_id, 0.5 FROM post_impressions pi JOIN posts p2 ON p2.id = pi.post_id
                  WHERE pi.user_id = \(uuid: userID) AND pi.view_ms >= \(unsafeRaw: String(longReadMs))
                    AND pi.first_seen_at > \(closeSince) AND pi.first_seen_at <= \(bind: asOf)
                UNION ALL SELECT m.sender_id, 0.3 FROM messages m
                  JOIN conversations cv ON cv.id = m.conversation_id AND NOT cv.is_group
                  JOIN conversation_participants me ON me.conversation_id = cv.id AND me.user_id = \(uuid: userID)
                  WHERE m.sender_id <> \(uuid: userID) AND m.deleted_at IS NULL
                    AND m.created_at > \(closeSince) AND m.created_at <= \(bind: asOf)
              ) x WHERE x.author_id <> \(uuid: userID) GROUP BY x.author_id
            ),
            -- Only these are scored: the newest posts in the mode, everything
            -- by your connections and follows, and what your peers lifted.
            -- Scoring every post ever posted grew with the whole table.
            cand AS (
              (SELECT np.id FROM posts np
                WHERE np.mode = \(bind: mode) AND np.status = 'posted'
                  AND np.created_at > \(bind: asOf) - INTERVAL '\(unsafeRaw: String(candidateDays)) days'
                  AND np.created_at <= \(bind: asOf)
                ORDER BY np.created_at DESC LIMIT \(unsafeRaw: String(maxCandidates)))
              UNION
              SELECT np.id FROM posts np
                WHERE np.mode = \(bind: mode) AND np.status = 'posted' AND np.author_id IN (
                  SELECT CASE WHEN co.requester_id = \(uuid: userID) THEN co.addressee_id ELSE co.requester_id END
                    FROM connections co WHERE co.status = 'accepted' AND co.mode = \(bind: mode)
                      AND (co.requester_id = \(uuid: userID) OR co.addressee_id = \(uuid: userID))
                  UNION SELECT fo.followee_id FROM follows fo
                    WHERE fo.follower_id = \(uuid: userID) AND fo.mode = \(bind: mode))
              UNION
              SELECT post_id FROM cf
            ),
            scored AS (
              SELECT p.id::text AS id, p.content, p.content_format, p.mode, p.privacy, p.image_urls[1] AS image_url, p.image_urls, p.image_alts, p.article_title, p.link_url,
                p.lang, \(unsafeRaw: TranslationService.translatedColumn("p")) AS translated_text,
                p.like_count, p.comment_count, p.share_count, p.created_at, p.edited_at, p.post_type, p.is_pinned, p.pinned_at, p.shared_post_id::text AS shared_post_id,
                EXISTS(SELECT 1 FROM post_likes pl WHERE pl.post_id = p.id AND pl.user_id = \(uuid: userID)) AS is_liked,
                EXISTS(SELECT 1 FROM connections co WHERE co.status = 'accepted' AND co.mode = \(bind: mode)
                  AND ((co.requester_id = p.author_id AND co.addressee_id = \(uuid: userID))
                    OR (co.addressee_id = p.author_id AND co.requester_id = \(uuid: userID)))) AS is_connection,
                \(semanticExpr) AS semantic,
                EXISTS(SELECT 1 FROM follows fo WHERE fo.follower_id = \(uuid: userID) AND fo.followee_id = p.author_id
                  AND fo.mode = \(bind: mode)) AS is_following,
                COALESCE(MAX(aff.raw), 0)::float AS affinity,
                COALESCE(MAX(cf.s), 0)::float AS peer_score,
                u.location AS author_location,
                EXP(- (EXTRACT(EPOCH FROM (\(bind: asOf) - p.created_at)) / 3600.0) / \(unsafeRaw: String(recencyTauHours)))::float AS recency,
                -- Interactions per viewer (see engagementScore). Viewers and
                -- "seen" are counted as of the first page (asOf), so scrolling
                -- (which records new sightings) can't reshuffle later pages.
                ((p.like_count + 2 * p.comment_count + 3 * p.share_count)::float
                  / ((SELECT COUNT(*) FROM post_impressions pv
                      WHERE pv.post_id = p.id AND pv.first_seen_at < \(bind: asOf)) + \(unsafeRaw: String(ratePrior)))
                  / ((p.like_count + 2 * p.comment_count + 3 * p.share_count)::float
                     / ((SELECT COUNT(*) FROM post_impressions pv
                         WHERE pv.post_id = p.id AND pv.first_seen_at < \(bind: asOf)) + \(unsafeRaw: String(ratePrior)))
                     + \(unsafeRaw: String(rateHalf))))::float AS engagement,
                COALESCE((SELECT CASE WHEN ps.first_seen_at > \(bind: asOf) - INTERVAL '\(unsafeRaw: String(Int(seenRecentHours))) hours'
                                      THEN \(unsafeRaw: String(seenRecentPenalty)) ELSE \(unsafeRaw: String(seenOlderPenalty)) END
                          FROM post_impressions ps
                          WHERE ps.user_id = \(uuid: userID) AND ps.post_id = p.id AND ps.first_seen_at < \(bind: asOf)), 0)::float AS seen_penalty,
                -- Your "Not interested" / "Show more like this" (see feedbackAdjustment):
                -- posts like those, and by their authors, for 30 days.
                (\(feedbackTerm(kind: "more", similar: true, userID: userID, asOf: asOf, weight: moreSimilarBoost))
                 + \(feedbackTerm(kind: "more", similar: false, userID: userID, asOf: asOf, weight: moreAuthorBoost))
                 - \(feedbackTerm(kind: "less", similar: true, userID: userID, asOf: asOf, weight: lessSimilarPenalty))
                 - \(feedbackTerm(kind: "less", similar: false, userID: userID, asOf: asOf, weight: lessAuthorPenalty))
                )::float AS feedback_adjust,
                (CASE WHEN p.shared_post_id IS NOT NULL THEN (
                  SELECT json_build_object('id', sp.id, 'content', sp.content, 'content_format', sp.content_format, 'image_url', sp.image_urls[1], 'image_urls', sp.image_urls, 'image_alts', sp.image_alts, 'lang', sp.lang, 'translated_text', \(unsafeRaw: TranslationService.translatedColumn("sp")),
                    'link_url', sp.link_url, 'article_title', sp.article_title, 'created_at', sp.created_at,
                    'author', json_build_object('id', su.id, 'username', su.username,
                      'display_name', \(unsafeRaw: PersonaSQL.expr("display_name", modeRef: "sp.mode", alias: "su")),
                      'avatar_color', su.avatar_color, 'avatar_url', \(unsafeRaw: PersonaSQL.expr("avatar_url", modeRef: "sp.mode", alias: "su"))))
                  FROM posts sp JOIN users su ON su.id = sp.author_id WHERE sp.id = p.shared_post_id AND sp.status = 'posted'
                ) ELSE NULL END)::text AS shared_post,
                (SELECT json_build_object('id', sc.id, 'name', sc.name, 'cover_url', sc.cover_url, 'cover_color', sc.cover_color,
                    'icon_emoji', sc.icon_emoji, 'member_count', sc.member_count, 'privacy', sc.privacy)
                  FROM communities sc WHERE sc.id = p.shared_community_id)::text AS shared_community,
                json_build_object('id', u.id, 'username', u.username,
                  'display_name', \(unsafeRaw: PersonaSQL.expr("display_name", modeRef: "p.mode")),
                  'avatar_color', u.avatar_color, 'avatar_url', \(unsafeRaw: PersonaSQL.expr("avatar_url", modeRef: "p.mode")),
                  'job_title', u.job_title, 'company', u.company, 'is_official', u.app_role = 'admin')::text AS author,
                COALESCE(json_agg(DISTINCT pt.tag) FILTER (WHERE pt.tag IS NOT NULL AND pt.source = 'user'), '[]')::text AS tags,
                \(PostStore.typeDataColumns(userID))
                (CASE WHEN p.community_id IS NOT NULL THEN (
                  SELECT json_build_object('id', co.id, 'name', co.name, 'icon_emoji', co.icon_emoji, 'avatar_url', co.avatar_url,
                'privacy', co.privacy, 'audience', COALESCE(p.community_audience, 'members'))
                  FROM communities co WHERE co.id = p.community_id
                ) ELSE NULL END)::text AS community
              FROM cand
              JOIN posts p ON p.id = cand.id
              JOIN users u ON u.id = p.author_id
              -- LEFT (not INNER) join: a post with no embedding chunk yet,
              -- because its async embed job hasn't run, is still queued, or
              -- Ollama was unavailable when it tried. Must still be a feed
              -- candidate, just with no semantic signal (see semanticExpr
              -- above), not silently erased from the feed until it's embedded.
              -- `c.source_type = 'post'` has to live in this ON clause, not
              -- WHERE below, WHERE would drop every unmatched (NULL) row and
              -- turn this back into an INNER JOIN in all but name.
              LEFT JOIN user_embedding_chunks c ON c.source_id = p.id AND c.source_type = 'post'
              LEFT JOIN post_tags pt ON pt.post_id = p.id
              LEFT JOIN aff ON aff.author_id = p.author_id
              LEFT JOIN cf ON cf.post_id = p.id
              WHERE p.mode = \(bind: mode) AND p.status = 'posted'
                -- Items for sale compete like any post; sold ones drop out.
                AND NOT EXISTS (SELECT 1 FROM listing_posts lsold WHERE lsold.post_id = p.id AND lsold.status = 'sold')
                AND \(ListingStore.notHiddenFromFriendClause(userID))
                AND (p.community_id IS NULL OR p.author_id = \(uuid: userID)
                  OR EXISTS (SELECT 1 FROM communities co2 WHERE co2.id = p.community_id AND co2.privacy = 'public'
                    AND p.community_audience = 'public')
                  OR EXISTS (SELECT 1 FROM community_members cm2 WHERE cm2.community_id = p.community_id AND cm2.user_id = \(uuid: userID)))
                AND NOT EXISTS (SELECT 1 FROM community_members cmMute
                  WHERE cmMute.community_id = p.community_id AND cmMute.user_id = \(uuid: userID) AND cmMute.muted = TRUE)
                AND p.author_id <> \(uuid: userID)
                AND NOT EXISTS (SELECT 1 FROM user_blocks ub
                  WHERE (ub.blocker_id = \(uuid: userID) AND ub.blocked_id = p.author_id)
                     OR (ub.blocker_id = p.author_id AND ub.blocked_id = \(uuid: userID)))
                AND \(AccountBans.visible(userRef: "p.author_id", modeColumn: "p.mode", viewer: userID))
                AND NOT EXISTS (SELECT 1 FROM hidden_posts hp WHERE hp.user_id = \(uuid: userID) AND hp.post_id = p.id)
                AND \(PostStore.notHiddenAuthorClause(userID))
                AND NOT EXISTS (SELECT 1 FROM post_feedback pf
                  WHERE pf.user_id = \(uuid: userID) AND pf.post_id = p.id AND pf.kind = 'less')
                AND \(PostStore.notMutedWordsClause(userID))
                -- Who may see it: public, or friends-only for friends, and a locked
                -- persona's posts only for its friends (the same rule as opening one).
                -- The official account sees them all.
                AND (\(PostStore.audienceClause(userID)) OR \(AccountBans.adminViewer(userID)))
              GROUP BY p.id, u.id, c.id
            ),
            ranked AS (
              SELECT *, (\(unsafeRaw: String(wSemantic)) * semantic + \(unsafeRaw: String(wRecency)) * recency
                + \(unsafeRaw: String(wEngagement)) * engagement
                -- Closeness to the author (see closeness), or a small lift for
                -- someone new to you.
                + \(unsafeRaw: String(closenessBoost)) * LEAST(1,
                    (CASE WHEN is_connection THEN \(unsafeRaw: String(connectionBase)) ELSE 0 END)
                  + (CASE WHEN is_following THEN \(unsafeRaw: String(followBase)) ELSE 0 END)
                  + \(unsafeRaw: String(interactionShare)) * affinity / (affinity + \(unsafeRaw: String(interactionHalf))))
                + CASE WHEN NOT is_connection AND NOT is_following AND affinity = 0 AND seen_penalty = 0
                    THEN \(unsafeRaw: String(newAuthorBoost)) ELSE 0 END
                -- People like you engaged with it (see peerLift).
                + \(unsafeRaw: String(peerBoost)) * peer_score / (peer_score + \(unsafeRaw: String(peerHalf)))
                + \(coldStart)
                - seen_penalty + feedback_adjust)::float AS score
              FROM scored WHERE
            """
            // Deliberately NOT bypassing this gate for chunk-less posts (e.g.
            // "is_connection OR c.id IS NULL OR ..."): a handful of unscored
            // posts squeaking through here would make `rows` non-empty below,
            // which would suppress the `relaxed` retry for a viewer with a
            // taste vector but zero genuinely strong matches. Trading a
            // small, correct fallback (relaxed → the full pool, ranked
            // recency/engagement-only) for a much worse one (just those few
            // stray unscored posts). Unscored posts still surface via that
            // same relaxed path once matches run out; they just don't skip
            // the relevance bar in the confident, non-relaxed pass.
            // The personalised pass also leaves out what you saw in the last
            // few days and anything you said "Not interested" to (or its
            // author): otherwise those still beat every post below the
            // relevance bar. The relaxed pass keeps them, sunk by their penalty.
            q = q + ((hasTaste && !relaxed)
                ? " (is_connection OR is_following OR semantic >= \(unsafeRaw: String(discoveryThreshold)) OR peer_score >= \(unsafeRaw: String(peerStrictMin))) AND seen_penalty < \(unsafeRaw: String(seenRecentPenalty)) AND feedback_adjust >= 0"
                : " TRUE")
            q = q + " ) SELECT * FROM ranked WHERE 1 = 1"
            if let d = decoded {
                // `id` here is `p.id::text` (see the SELECT above), not a raw
                // uuid column, binding this as `\(uuid:)` sends a `::uuid`
                // typed parameter against a `text` value, which Postgres
                // rejects outright ("operator does not exist: text < uuid").
                // That made every second-page request of this feed 500,
                // silently swallowed by the client's "scrolling further will
                // retry" catch, i.e. pagination has never actually worked
                // past page 1. Plain `\(bind:)` matches the column's real type.
                q = q + " AND (score < \(bind: d.score) OR (score = \(bind: d.score) AND id < \(bind: d.id)))"
            }
            q = q + " ORDER BY score DESC, id DESC LIMIT \(bind: limit + 1)"
            let query = q
            // JIT off for this one query: its many per-row subqueries push the
            // planner's cost estimate past `jit_above_cost`, and Postgres then
            // spent ~370 ms compiling ~800 functions for a query that runs in
            // ~25 ms (every page after the first). SET LOCAL needs the
            // transaction, and the session keeps it on one connection.
            return try await db.withSession { s in
                try await s.raw("BEGIN").run()
                do {
                    try await s.raw("SET LOCAL jit = off").run()
                    let rows = try await s.raw(query).all(decoding: FeedRow.self)
                    try await s.raw("COMMIT").run()
                    return rows
                } catch {
                    _ = try? await s.raw("ROLLBACK").run()
                    throw error
                }
            }
        }

        var rows = try await run(relaxed: relaxed)
        // Widen to the relaxed (no-relevance-floor) pool whenever the strict,
        // personalized pass didn't fill a whole page, not just when the
        // very first page came back completely empty. A viewer can easily
        // have a handful of connection/high-similarity posts (page 1 isn't
        // empty, so the old check never fired) and then run out of them a
        // page or two later, at which point pagination would previously just
        // stop cold even though plenty of less-personally-relevant posts
        // remain. Merge rather than replace, since the strict rows are still
        // valid and already the most relevant. Just top the page up with
        // whatever the relaxed pass finds that the strict pass didn't
        // already return, then re-rank the combined set by the same score so
        // ordering stays consistent either way.
        if hasTaste && !relaxed && rows.count <= limit {
            relaxed = true
            let relaxedRows = try await run(relaxed: true)
            let seen = Set(rows.map(\.id))
            rows = Array((rows + relaxedRows.filter { !seen.contains($0.id) })
                .sorted { $0.score != $1.score ? $0.score > $1.score : $0.id > $1.id }
                .prefix(limit + 1))
        }
        let hasMore = rows.count > limit
        let page = hasMore ? Array(rows.prefix(limit)) : rows
        let dec = JSONCoding.makeDecoder()
        func parse<T: Decodable>(_ s: String?, _ t: T.Type) throws -> T? {
            guard let s, s != "null" else { return nil }
            return try dec.decode(T.self, from: Data(s.utf8))
        }
        let posts = try page.map { r -> FeedPostObject in
            FeedPostObject(
                id: r.id, content: r.content, content_format: r.content_format, mode: r.mode, privacy: r.privacy,
                image_url: r.image_url, image_urls: r.image_urls, image_alts: r.image_alts, lang: r.lang, translated_text: r.translated_text, article_title: r.article_title, link_url: r.link_url,
                like_count: r.like_count, comment_count: r.comment_count, share_count: r.share_count,
                created_at: r.created_at, edited_at: r.edited_at, post_type: r.post_type, is_pinned: r.is_pinned, pinned_at: r.pinned_at,
                shared_post_id: r.shared_post_id, is_liked: r.is_liked, is_connection: r.is_connection,
                semantic: r.semantic, recency: r.recency, engagement: r.engagement,
                shared_post: (r.shared_post != nil && r.shared_post != "null") ? try dec.decode(PostObject.SharedPost.self, from: Data(r.shared_post!.utf8)) : nil,
                author: try dec.decode(PostObject.PostAuthor.self, from: Data(r.author.utf8)),
                tags: (try? dec.decode([String].self, from: Data(r.tags.utf8))) ?? [],
                event_data: try parse(r.event_data, PostObject.EventData.self),
                poll_data: try parse(r.poll_data, PostObject.PollData.self),
                job_data: try parse(r.job_data, PostObject.JobData.self),
                listing_data: try parse(r.listing_data, PostObject.ListingData.self),
                community: (r.community != nil && r.community != "null") ? try dec.decode(PostObject.CommunityRef.self, from: Data(r.community!.utf8)) : nil,
                score: r.score,
                shared_community: (r.shared_community != nil && r.shared_community != "null")
                    ? try dec.decode(PostObject.SharedCommunity.self, from: Data(r.shared_community!.utf8)) : nil)
        }
        let next = hasMore ? encodeCursor(page.last!.score, page.last!.id, relaxed: relaxed, asOf: asOf) : nil
        // Variety within the page; the cursor above already marks where the
        // page ends by score, so reordering doesn't affect the next page.
        let spreadPosts = spread(posts, author: { $0.author.id }, topic: { $0.tags.first })
        return (spreadPosts, next)
    }
}

/// Feed recommendation row. Same fields as `PostObject` minus `is_saved`,
/// plus the internal `score` (Node returns it too). The event / poll / job
/// data must be here: without it those posts showed only their text in For you.
struct FeedPostObject: Content {
    var id: String
    @NullCoded var content: String?
    /// "markdown" or "plain"; without it the app showed Markdown posts as raw text.
    var content_format: String? = nil
    var mode: String
    var privacy: String
    @NullCoded var image_url: String?
    @NullCoded var image_urls: [String]?
    @NullCoded var image_alts: [String]?
    @NullCoded var lang: String?
    @NullCoded var translated_text: String?
    @NullCoded var article_title: String?
    @NullCoded var link_url: String?
    var like_count: Int
    var comment_count: Int
    var share_count: Int
    var created_at: Date
    @NullCoded var edited_at: Date? = nil
    var post_type: String
    var is_pinned: Bool
    @NullCoded var pinned_at: Date?
    @NullCoded var shared_post_id: String?
    var is_liked: Bool
    var is_connection: Bool
    var semantic: Double
    var recency: Double
    var engagement: Double
    @NullCoded var shared_post: PostObject.SharedPost?
    var author: PostObject.PostAuthor
    var tags: [String]
    @NullCoded var event_data: PostObject.EventData?
    @NullCoded var poll_data: PostObject.PollData?
    @NullCoded var job_data: PostObject.JobData?
    @NullCoded var listing_data: PostObject.ListingData? = nil
    @NullCoded var community: PostObject.CommunityRef?
    var score: Double
    /// A community shared to the feed (its card under the note).
    @NullCoded var shared_community: PostObject.SharedCommunity? = nil
}

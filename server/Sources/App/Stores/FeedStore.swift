import Vapor
import SQLKit

/// Port of `backend/src/models/feedModel.js` — the personalized newsfeed.
/// Taste vector built in Swift from `user_embedding_chunks` (populated by the
/// embed worker), then a keyset-paginated blended-ranking CTE.
enum FeedStore {
    static let wSemantic = 0.50, wRecency = 0.35, wEngagement = 0.15
    static let connectionBoost = 0.15, discoveryThreshold = 0.65
    static let recencyTauHours = 72.0, engagementCap = 500.0
    static let wProfile = 0.6, wBehavior = 0.4, recentLikes = 20

    struct Cursor: Codable { var score: Double; var id: String; var relaxed: Bool? }

    static func encodeCursor(_ score: Double, _ id: String, relaxed: Bool) -> String {
        let c = relaxed ? Cursor(score: score, id: id, relaxed: true) : Cursor(score: score, id: id, relaxed: nil)
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

    static func buildTasteVector(_ userID: String, on db: any SQLDatabase) async throws -> [Double]? {
        struct V: Decodable { let vec: String }
        let profile = try await db.raw("SELECT embedding::text AS vec FROM user_embedding_chunks WHERE user_id = \(uuid: userID) AND source_type = 'user_profile'")
            .all(decoding: V.self).map { parseVec($0.vec) }
        let liked = try await db.raw("""
            SELECT c.embedding::text AS vec FROM post_likes pl
            JOIN user_embedding_chunks c ON c.source_type = 'post' AND c.source_id = pl.post_id
            WHERE pl.user_id = \(uuid: userID) ORDER BY pl.created_at DESC LIMIT \(bind: recentLikes)
            """).all(decoding: V.self).map { parseVec($0.vec) }
        if profile.isEmpty && liked.isEmpty { return nil }
        let taste: [Double]
        if !profile.isEmpty && !liked.isEmpty {
            let p = meanVec(profile), b = meanVec(liked)
            taste = p.enumerated().map { wProfile * $0.element + wBehavior * b[$0.offset] }
        } else {
            taste = meanVec(profile.isEmpty ? liked : profile)
        }
        return normalize(taste)
    }

    struct FeedRow: Decodable {
        var id: String
        var content: String?
        var mode: String
        var privacy: String
        var image_url: String?
        var image_urls: [String]?
        var article_title: String?
        var link_url: String?
        var like_count: Int
        var comment_count: Int
        var share_count: Int
        var created_at: Date
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
        var score: Double
    }

    static func getRecommendedFeed(userID: String, mode: String, cursor: String?, limit: Int, on db: any SQLDatabase)
        async throws -> (posts: [FeedPostObject], nextCursor: String?)
    {
        let taste = try await buildTasteVector(userID, on: db)
        let hasTaste = taste != nil
        let decoded = cursor.flatMap(decodeCursor)
        var relaxed = decoded?.relaxed == true

        func run() async throws -> [FeedRow] {
            let semanticExpr: SQLQueryString = hasTaste
                ? "(1 - (c.embedding <=> \(bind: toVectorLiteral(taste!))::vector))::float"
                : "0::float"
            var q: SQLQueryString = """
            WITH scored AS (
              SELECT p.id::text AS id, p.content, p.mode, p.privacy, p.image_urls[1] AS image_url, p.image_urls, p.article_title, p.link_url,
                p.like_count, p.comment_count, p.share_count, p.created_at, p.post_type, p.is_pinned, p.pinned_at, p.shared_post_id::text AS shared_post_id,
                EXISTS(SELECT 1 FROM post_likes pl WHERE pl.post_id = p.id AND pl.user_id = \(uuid: userID)) AS is_liked,
                EXISTS(SELECT 1 FROM connections co WHERE co.status = 'accepted' AND co.mode = \(bind: mode)
                  AND ((co.requester_id = p.author_id AND co.addressee_id = \(uuid: userID))
                    OR (co.addressee_id = p.author_id AND co.requester_id = \(uuid: userID)))) AS is_connection,
                \(semanticExpr) AS semantic,
                EXP(- (EXTRACT(EPOCH FROM (NOW() - p.created_at)) / 3600.0) / \(unsafeRaw: String(recencyTauHours)))::float AS recency,
                LEAST(1, LN(1 + p.like_count + 2 * p.comment_count) / LN(1 + \(unsafeRaw: String(Int(engagementCap)))))::float AS engagement,
                (CASE WHEN p.shared_post_id IS NOT NULL THEN (
                  SELECT json_build_object('id', sp.id, 'content', sp.content, 'image_url', sp.image_urls[1], 'image_urls', sp.image_urls,
                    'link_url', sp.link_url, 'article_title', sp.article_title, 'created_at', sp.created_at,
                    'author', json_build_object('id', su.id, 'username', su.username,
                      'display_name', \(unsafeRaw: PersonaSQL.expr("display_name", modeRef: "sp.mode", alias: "su")),
                      'avatar_color', su.avatar_color, 'avatar_url', \(unsafeRaw: PersonaSQL.expr("avatar_url", modeRef: "sp.mode", alias: "su"))))
                  FROM posts sp JOIN users su ON su.id = sp.author_id WHERE sp.id = p.shared_post_id AND sp.status = 'posted'
                ) ELSE NULL END)::text AS shared_post,
                json_build_object('id', u.id, 'username', u.username,
                  'display_name', \(unsafeRaw: PersonaSQL.expr("display_name", modeRef: "p.mode")),
                  'avatar_color', u.avatar_color, 'avatar_url', \(unsafeRaw: PersonaSQL.expr("avatar_url", modeRef: "p.mode")),
                  'job_title', u.job_title, 'company', u.company)::text AS author,
                COALESCE(json_agg(DISTINCT pt.tag) FILTER (WHERE pt.tag IS NOT NULL), '[]')::text AS tags
              FROM user_embedding_chunks c
              JOIN posts p ON p.id = c.source_id
              JOIN users u ON u.id = p.author_id
              LEFT JOIN post_tags pt ON pt.post_id = p.id
              WHERE c.source_type = 'post' AND p.mode = \(bind: mode) AND p.status = 'posted'
                AND p.community_id IS NULL AND p.author_id <> \(uuid: userID)
                AND NOT EXISTS (SELECT 1 FROM user_blocks ub
                  WHERE (ub.blocker_id = \(uuid: userID) AND ub.blocked_id = p.author_id)
                     OR (ub.blocker_id = p.author_id AND ub.blocked_id = \(uuid: userID)))
                AND NOT EXISTS (SELECT 1 FROM hidden_posts hp WHERE hp.user_id = \(uuid: userID) AND hp.post_id = p.id)
                AND (p.privacy = 'public' OR (p.privacy = 'friends' AND EXISTS (SELECT 1 FROM connections cf
                  WHERE cf.status = 'accepted' AND ((cf.requester_id = p.author_id AND cf.addressee_id = \(uuid: userID))
                    OR (cf.addressee_id = p.author_id AND cf.requester_id = \(uuid: userID))))))
              GROUP BY p.id, u.id, c.id
            ),
            ranked AS (
              SELECT *, (\(unsafeRaw: String(wSemantic)) * semantic + \(unsafeRaw: String(wRecency)) * recency
                + \(unsafeRaw: String(wEngagement)) * engagement
                + CASE WHEN is_connection THEN \(unsafeRaw: String(connectionBoost)) ELSE 0 END)::float AS score
              FROM scored WHERE
            """
            q = q + ((hasTaste && !relaxed) ? " (is_connection OR semantic >= \(unsafeRaw: String(discoveryThreshold)))" : " TRUE")
            q = q + " ) SELECT * FROM ranked WHERE 1 = 1"
            if let d = decoded {
                q = q + " AND (score < \(bind: d.score) OR (score = \(bind: d.score) AND id < \(uuid: d.id)))"
            }
            q = q + " ORDER BY score DESC, id DESC LIMIT \(bind: limit + 1)"
            return try await db.raw(q).all(decoding: FeedRow.self)
        }

        var rows = try await run()
        if rows.isEmpty && hasTaste && !relaxed && decoded == nil {
            relaxed = true
            rows = try await run()
        }
        let hasMore = rows.count > limit
        let page = hasMore ? Array(rows.prefix(limit)) : rows
        let dec = JSONCoding.makeDecoder()
        let posts = try page.map { r -> FeedPostObject in
            FeedPostObject(
                id: r.id, content: r.content, mode: r.mode, privacy: r.privacy,
                image_url: r.image_url, image_urls: r.image_urls, article_title: r.article_title, link_url: r.link_url,
                like_count: r.like_count, comment_count: r.comment_count, share_count: r.share_count,
                created_at: r.created_at, post_type: r.post_type, is_pinned: r.is_pinned, pinned_at: r.pinned_at,
                shared_post_id: r.shared_post_id, is_liked: r.is_liked, is_connection: r.is_connection,
                semantic: r.semantic, recency: r.recency, engagement: r.engagement,
                shared_post: (r.shared_post != nil && r.shared_post != "null") ? try dec.decode(PostObject.SharedPost.self, from: Data(r.shared_post!.utf8)) : nil,
                author: try dec.decode(PostObject.PostAuthor.self, from: Data(r.author.utf8)),
                tags: (try? dec.decode([String].self, from: Data(r.tags.utf8))) ?? [],
                score: r.score)
        }
        let next = hasMore ? encodeCursor(page.last!.score, page.last!.id, relaxed: relaxed) : nil
        return (posts, next)
    }
}

/// Feed recommendation row — same fields as `PostObject` minus `is_saved` /
/// `event_data` / `poll_data`, plus the internal `score` (Node returns it too).
struct FeedPostObject: Content {
    var id: String
    @NullCoded var content: String?
    var mode: String
    var privacy: String
    @NullCoded var image_url: String?
    @NullCoded var image_urls: [String]?
    @NullCoded var article_title: String?
    @NullCoded var link_url: String?
    var like_count: Int
    var comment_count: Int
    var share_count: Int
    var created_at: Date
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
    var score: Double
}

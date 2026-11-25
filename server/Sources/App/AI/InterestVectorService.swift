import Vapor
import SQLKit

/// What each person shows interest in (`user_interest_vectors`, migration 144):
/// the public posts they wrote or reacted to lately, grouped into a few
/// interests per mode. Built from post embeddings that already exist, so a
/// rebuild is arithmetic only, no model call.
enum InterestVectorService {
    static let maxClusters = 5
    /// Older activity no longer says what someone is into now.
    static let windowDays = 180
    /// Writing about something is the strongest signal; reactions use the
    /// search weights (`SearchStore.wReactCommentOrShare`, `wReactLike`).
    static let wAuthored = 1.0

    // MARK: - Clustering
    struct Cluster: Equatable { let centroid: [Double]; let weight: Double; let postCount: Int }

    /// `FeedStore.clusterTaste`'s interests with what each one holds, heaviest
    /// first. A cluster no post ended up in is dropped.
    static func clusters(_ vectors: [[Double]], weights: [Double], maxK: Int = maxClusters) -> [Cluster] {
        let centroids = FeedStore.clusterTaste(vectors, weights: weights, maxK: maxK)
        guard !centroids.isEmpty else { return [] }
        var weight = [Double](repeating: 0, count: centroids.count)
        var count = [Int](repeating: 0, count: centroids.count)
        for (i, v) in vectors.enumerated() where v.count == centroids[0].count {
            let p = FeedStore.normalize(v)
            let sims = centroids.map { c in zip(p, c).reduce(0) { $0 + $1.0 * $1.1 } }
            let best = sims.indices.max { sims[$0] < sims[$1] }!
            weight[best] += i < weights.count ? weights[i] : 1
            count[best] += 1
        }
        return centroids.indices.filter { count[$0] > 0 }
            .map { Cluster(centroid: centroids[$0], weight: weight[$0], postCount: count[$0]) }
            .sorted { $0.weight > $1.weight }
    }

    // MARK: - Activity signals
    /// `signals(user_id, mode, post_id, w)`: every public post someone wrote or
    /// reacted to within the window that has an embedding, at their strongest
    /// signal for it. Both the build and the staleness check read this, so
    /// they can't disagree.
    private static func signalsCTE(userID: String? = nil, mode: String? = nil) -> SQLQueryString {
        let since: SQLQueryString = "NOW() - INTERVAL '\(unsafeRaw: String(windowDays)) days'"
        let author: SQLQueryString = userID.map { " AND p.author_id = \(uuid: $0)" } ?? ""
        let reactor: SQLQueryString = userID.map { " AND r.user_id = \(uuid: $0)" } ?? ""
        let inMode: SQLQueryString = mode.map { " AND p.mode = \(bind: $0)" } ?? ""
        return """
            signals AS (
              SELECT s.user_id, s.mode, s.post_id, MAX(s.w) AS w
              FROM (
                SELECT p.author_id AS user_id, p.mode, p.id AS post_id, \(bind: wAuthored)::float8 AS w
                FROM posts p
                WHERE p.status = 'posted' AND p.privacy = 'public' AND p.created_at > \(since)\(author)\(inMode)
                UNION ALL
                SELECT r.user_id, p.mode, p.id,
                       CASE WHEN r.kind = 'like' THEN \(bind: SearchStore.wReactLike)::float8
                            ELSE \(bind: SearchStore.wReactCommentOrShare)::float8 END
                FROM post_reactions r JOIN posts p ON p.id = r.post_id
                WHERE p.status = 'posted' AND p.privacy = 'public' AND r.user_id <> p.author_id
                  -- Reactions are activity: they stop counting when "Personalise
                  -- with my activity" is off (ActivityTracking).
                  AND EXISTS (SELECT 1 FROM users ru WHERE ru.id = r.user_id AND ru.track_activity)
                  AND r.created_at > \(since)\(reactor)\(inMode)
              ) s
              JOIN users u ON u.id = s.user_id AND u.deleted_at IS NULL
              WHERE EXISTS (SELECT 1 FROM user_embedding_chunks c
                            WHERE c.source_type = 'post' AND c.source_id = s.post_id)
              GROUP BY s.user_id, s.mode, s.post_id
            )
            """
    }

    private static let hashSQL: SQLQueryString =
        "md5(string_agg(post_id::text || ':' || w::text, ',' ORDER BY post_id))"

    // MARK: - Rebuilds
    /// Rebuilds one person's interests in one mode. No signals → no rows.
    static func refresh(userID: String, mode: String, on db: any SQLDatabase) async throws {
        struct Row: Decodable { let w: Double; let vec: String; let h: String }
        let rows = try await db.raw("""
            WITH \(signalsCTE(userID: userID, mode: mode))
            SELECT s.w, c.embedding::text AS vec, (SELECT \(hashSQL) FROM signals) AS h
            FROM signals s
            JOIN user_embedding_chunks c ON c.source_type = 'post' AND c.source_id = s.post_id AND c.chunk_index = 0
            ORDER BY s.post_id
            """).all(decoding: Row.self)
        let built = clusters(rows.map { FeedStore.parseVec($0.vec) }, weights: rows.map(\.w))
        for (i, c) in built.enumerated() {
            try await db.raw("""
                INSERT INTO user_interest_vectors (user_id, mode, cluster_index, embedding, weight, post_count, source_hash)
                VALUES (\(uuid: userID), \(bind: mode), \(bind: i), \(bind: SearchStore.vecLiteral(c.centroid))::vector,
                        \(bind: c.weight), \(bind: c.postCount), \(bind: rows[0].h))
                ON CONFLICT (user_id, mode, cluster_index)
                DO UPDATE SET embedding = EXCLUDED.embedding, weight = EXCLUDED.weight, post_count = EXCLUDED.post_count,
                              source_hash = EXCLUDED.source_hash, updated_at = NOW()
                """).run()
        }
        try await db.raw("""
            DELETE FROM user_interest_vectors
            WHERE user_id = \(uuid: userID) AND mode = \(bind: mode) AND cluster_index >= \(bind: built.count)
            """).run()
    }

    /// A post's embedding was just built: its author's interests can count it now.
    static func refreshAuthor(ofPost postID: String, on db: any SQLDatabase) async throws {
        struct P: Decodable { let author_id: String; let mode: String }
        guard let p = try await db.raw("SELECT author_id::text AS author_id, mode FROM posts WHERE id = \(uuid: postID)")
            .first(decoding: P.self) else { return }
        try await refresh(userID: p.author_id, mode: p.mode, on: db)
    }

    /// Rebuilds everyone whose signals no longer match what their rows were
    /// built from: new posts or reactions, undone ones, and ones that aged out
    /// of the window. Returns how many (user, mode) pairs were rebuilt.
    @discardableResult
    static func sweep(on db: any SQLDatabase) async throws -> Int {
        struct Stale: Decodable { let user_id: String; let mode: String }
        let stale = try await db.raw("""
            WITH \(signalsCTE()),
            expected AS (SELECT user_id, mode, \(hashSQL) AS h FROM signals GROUP BY user_id, mode),
            stored AS (SELECT DISTINCT user_id, mode, source_hash AS h FROM user_interest_vectors)
            SELECT COALESCE(e.user_id, s.user_id)::text AS user_id, COALESCE(e.mode, s.mode) AS mode
            FROM expected e FULL JOIN stored s ON s.user_id = e.user_id AND s.mode = e.mode
            WHERE e.h IS DISTINCT FROM s.h
            """).all(decoding: Stale.self)
        for s in stale { try await refresh(userID: s.user_id, mode: s.mode, on: db) }
        return stale.count
    }
}

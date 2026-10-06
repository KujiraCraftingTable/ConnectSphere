import Vapor
import SQLKit

/// Port of `backend/src/models/searchModel.js` — the chunk-based people
/// vector-search CTE plus its helpers (`getUserContext`, `logSearch`,
/// `findCommunityEvidence`), and `entityLookupService`'s pure-SQL / vector
/// tiers (`exactMatch`, `findEntityCandidates`).
///
/// Folded review fixes vs the Node CTE:
///   • `chunk_pool` is filtered BEFORE the 200-row HNSW cap — soft-deleted
///     authors, non-`posted`/non-public post chunks, and mutual blocks vs the
///     searcher no longer waste a slot or influence a score.
///   • the user-level block exclusion always runs when a searcher is known.
enum SearchStore {
    static let chunkPoolSize = 200
    static let wMax = 0.7, wAvg = 0.3, wRetrieval = 0.85, wPersonal = 0.15
    /// Reacting to a matching post is evidence of interest, but weaker than
    /// writing about it: a reactor is credited the post's match × this weight.
    /// A comment or share takes more effort than a like.
    static let wReactLike = 0.8, wReactCommentOrShare = 0.9
    static let evidencePerUser = 5
    static let highConfidenceThreshold = 0.8
    static let suggestThreshold = 0.6

    static let datingKeywords: Set<String> = [
        "hẹn hò", "dating", "người yêu", "partner", "bạn đời",
        "tình cảm", "love", "romantic", "date", "yêu", "crush",
        "bạn trai", "bạn gái", "tìm người yêu",
    ]

    static func vecLiteral(_ v: [Double]) -> String {
        "[" + v.map { String($0) }.joined(separator: ",") + "]"
    }

    // MARK: nearestPosts (AI post search)

    struct PostHit: Decodable { let id: String; let sim: Double }

    /// Posted posts in `mode` whose embedded chunk is closest to `vector`
    /// (cosine), keeping those at or above `threshold` — the same 0.6 bar
    /// people search uses for chunk hits. Visibility (privacy, blocks,
    /// communities, hidden, muted) is deliberately not checked here: callers
    /// hydrate through `PostStore.findVisible`, which applies the feed's own
    /// rules, so the two can't drift apart.
    static func nearestPosts(_ vector: [Double], mode: String?, threshold: Double = 0.6,
                             limit: Int = 60, on db: any SQLDatabase) async throws -> [PostHit] {
        let lit = vecLiteral(vector)
        var q: SQLQueryString = """
            SELECT c.source_id::text AS id, (1 - (c.embedding <=> \(bind: lit)::vector))::float AS sim
            FROM user_embedding_chunks c
            JOIN posts p ON p.id = c.source_id
            WHERE c.source_type = 'post' AND p.status = 'posted'
            """
        if let m = mode { q = q + " AND p.mode = \(bind: m)" }
        q = q + " ORDER BY c.embedding <=> \(bind: lit)::vector LIMIT \(bind: limit)"
        return try await db.raw(q).all(decoding: PostHit.self).filter { $0.sim >= threshold }
    }

    // MARK: getUserContext / logSearch

    struct UserContext: Decodable { let gender: String?; let location: String? }
    static func getUserContext(_ userID: String, on db: any SQLDatabase) async throws -> UserContext? {
        try await db.raw("SELECT gender, location FROM users WHERE id = \(uuid: userID)").first(decoding: UserContext.self)
    }
    static func logSearch(_ query: String, mode: String?, on db: any SQLDatabase) async throws {
        try await db.raw("INSERT INTO search_logs (query, mode) VALUES (\(bind: query), \(bind: mode))").run()
    }

    // MARK: entity tiers

    struct EntityHit: Decodable { let id: String; let canonical_name: String; let category: String? }
    static func exactMatch(_ text: String, category: String?, on db: any SQLDatabase) async throws -> EntityHit? {
        let normalized = text.trimmingCharacters(in: .whitespaces).lowercased()
        return try await db.raw("""
            SELECT id::text AS id, canonical_name, category FROM interest_entities
            WHERE (LOWER(canonical_name) = \(bind: normalized)
                   OR \(bind: normalized) = ANY(SELECT LOWER(a) FROM UNNEST(aliases) a))
              AND (\(bind: category)::text IS NULL OR category = \(bind: category))
            LIMIT 1
            """).first(decoding: EntityHit.self)
    }

    struct EntityCandidate: Decodable { let entity_id: String; let canonical_name: String; let category: String?; let similarity: Double }
    static func findEntityCandidates(_ vec: [Double], category: String?, limit: Int, on db: any SQLDatabase) async throws -> [EntityCandidate] {
        let lit = vecLiteral(vec)
        return try await db.raw("""
            SELECT id::text AS entity_id, canonical_name, category,
                   (1 - (embedding <=> \(bind: lit)::vector))::float AS similarity
            FROM interest_entities
            WHERE embedding IS NOT NULL AND (\(bind: category)::text IS NULL OR category = \(bind: category))
            ORDER BY embedding <=> \(bind: lit)::vector
            LIMIT \(bind: limit)
            """).all(decoding: EntityCandidate.self)
    }

    // MARK: community evidence

    static func findCommunityEvidence(_ userIDs: [String], terms: [String], on db: any SQLDatabase) async throws -> [String: [String]] {
        guard !userIDs.isEmpty, !terms.isEmpty else { return [:] }
        let patterns = terms.map { "%\($0.lowercased())%" }
        struct R: Decodable { let user_id: String; let name: String; let member_count: Int }
        let rows = try await db.raw("""
            SELECT DISTINCT cm.user_id::text AS user_id, c.name, c.member_count
            FROM community_members cm
            JOIN communities c ON c.id = cm.community_id
            WHERE cm.user_id = ANY(\(bind: userIDs)::uuid[])
              AND c.privacy = 'public'
              AND (LOWER(c.name) LIKE ANY(\(bind: patterns)::text[])
                   OR LOWER(COALESCE(c.description, '')) LIKE ANY(\(bind: patterns)::text[])
                   OR EXISTS (SELECT 1 FROM community_tags ct
                              WHERE ct.community_id = c.id AND LOWER(ct.tag) LIKE ANY(\(bind: patterns)::text[])))
            ORDER BY cm.user_id, c.member_count DESC
            """).all(decoding: R.self)
        var byUser: [String: [String]] = [:]
        for r in rows where (byUser[r.user_id]?.count ?? 0) < 2 {
            byUser[r.user_id, default: []].append(r.name)
        }
        return byUser
    }

    // MARK: vectorSearch

    struct Params {
        var queryVector: [Double]
        var mode: String?
        var location: String?
        var targetGender: String?
        var targetAgeMin: Int?
        var targetAgeMax: Int?
        var hasDatingIntent = false
        var currentUserGender: String?
        var searchLat: Double?
        var searchLng: Double?
        var radiusKm: Double?
        var threshold = 0.6
        var excludeUserID: String?
        var interestGroups: [[String]]?
    }

    struct RawEvidence: Codable {
        var source_type: String
        var topic: String?
        var content: String?
        var similarity: Double?
        var post_count: Int?
        var latest_post_at: Date?
        var oldest_post_at: Date?
        /// Engagement evidence only, and only public reactions — like counts
        /// are never selected, so they can't reach the client.
        var commented_count: Int?
        var shared_count: Int?
    }
    struct RawUser: Decodable {
        var id: String; var username: String
        var display_name: String?; var bio: String?; var avatar_url: String?; var cover_url: String?
        var avatar_color: String?; var location: String?; var job_title: String?; var company: String?
        var default_mode: String?; var gender: String?; var age: Int?
        var follower_count: Int; var following_count: Int; var post_count: Int
        var interests: String; var skills: String   // ::text json
        var score: Double
        var match_evidence: String                  // ::text jsonb
        var mutual_count: Int
    }

    private static func jsNorm(_ s: String) -> String {
        s.lowercased()
            .replacingOccurrences(of: " city", with: "")
            .replacingOccurrences(of: " province", with: "")
            .replacingOccurrences(of: " ", with: "")
    }

    static func vectorSearch(_ p: Params, on db: any SQLDatabase) async throws -> [RawUser] {
        let lit = vecLiteral(p.queryVector)

        // ── chunk_pool (folded fix: pre-filter before the HNSW LIMIT) ──
        var pool: SQLQueryString = """
            SELECT c.user_id, c.source_type, c.source_id, c.topic, c.content,
                   (1 - (c.embedding <=> \(bind: lit)::vector))::float AS sim
            FROM user_embedding_chunks c
            JOIN users a ON a.id = c.user_id AND a.deleted_at IS NULL
            WHERE (c.source_type = 'user_profile'
                   OR EXISTS (SELECT 1 FROM posts pp WHERE pp.id = c.source_id
                              AND pp.status = 'posted' AND pp.privacy = 'public'
            """
        // Hobby and Work are separate worlds: a post only counts as evidence
        // (for its author, or for anyone who reacted to it) in its own mode.
        if let m = p.mode { pool = pool + " AND pp.mode = \(bind: m)" }
        pool = pool + "))"
        if let sid = p.excludeUserID {
            pool = pool + """
                 AND NOT EXISTS (SELECT 1 FROM user_blocks ub
                   WHERE (ub.blocker_id = \(uuid: sid) AND ub.blocked_id = c.user_id)
                      OR (ub.blocker_id = c.user_id AND ub.blocked_id = \(uuid: sid)))
                """
        }
        pool = pool + " ORDER BY c.embedding <=> \(bind: lit)::vector LIMIT \(unsafeRaw: String(chunkPoolSize))"

        // ── user-level hard filters (setup clause inlined with the bound mode) ──
        // Reactors can be any user, not just chunk owners from the pool.
        var wheres: [SQLQueryString] = ["u.deleted_at IS NULL"]
        if let m = p.mode {
            wheres.append("(CASE WHEN \(bind: m) = 'work' THEN u.work_display_name ELSE u.hobby_display_name END) IS NOT NULL")
        }
        if let sid = p.excludeUserID {
            wheres.append("u.id != \(uuid: sid)")
            wheres.append("""
                NOT EXISTS (SELECT 1 FROM user_blocks ub
                  WHERE (ub.blocker_id = \(uuid: sid) AND ub.blocked_id = u.id)
                     OR (ub.blocker_id = u.id AND ub.blocked_id = \(uuid: sid)))
                """)
            if let m = p.mode {
                wheres.append("""
                    NOT EXISTS (SELECT 1 FROM connections cc WHERE cc.status = 'accepted' AND cc.mode = \(bind: m)
                      AND ((cc.requester_id = \(uuid: sid) AND cc.addressee_id = u.id)
                           OR (cc.requester_id = u.id AND cc.addressee_id = \(uuid: sid))))
                    """)
            } else {
                wheres.append("""
                    NOT EXISTS (SELECT 1 FROM connections cc WHERE cc.status = 'accepted'
                      AND ((cc.requester_id = \(uuid: sid) AND cc.addressee_id = u.id)
                           OR (cc.requester_id = u.id AND cc.addressee_id = \(uuid: sid))))
                    """)
            }
        }
        if let loc = p.location {
            let norm = jsNorm(loc)
            wheres.append("REPLACE(REPLACE(REPLACE(LOWER(u.location), ' city', ''), ' province', ''), ' ', '') LIKE \(bind: "%\(norm)%")")
        }
        if let lat = p.searchLat, let lng = p.searchLng, let rad = p.radiusKm {
            wheres.append("""
                EXISTS (SELECT 1 FROM vn_wards w WHERE w.id = u.ward_id
                  AND (6371 * acos(cos(radians(\(bind: lat))) * cos(radians(w.lat))
                     * cos(radians(w.lng) - radians(\(bind: lng)))
                     + sin(radians(\(bind: lat))) * sin(radians(w.lat)))) <= \(bind: rad))
                """)
        }
        if let groups = p.interestGroups {
            for group in groups where !group.isEmpty {
                var ors: [SQLQueryString] = []
                var shown: [SQLQueryString] = []
                for kw in group {
                    let k = kw.lowercased()
                    ors.append("(LOWER(uix.interest) LIKE \(bind: "%\(k)%") OR \(bind: k) LIKE '%' || LOWER(uix.interest) || '%')")
                    shown.append("LOWER(hx.content) LIKE \(bind: "%\(k)%")")
                }
                // A declared interest satisfies the group — and so does shown
                // interest: a matching post they wrote or reacted to. Otherwise
                // people who never filled in their interests could never match.
                var clause: SQLQueryString = "(EXISTS (SELECT 1 FROM user_interests uix WHERE uix.user_id = u.id AND ("
                for (i, o) in ors.enumerated() { clause = clause + (i == 0 ? "" : " OR ") + o }
                clause = clause + ")) OR EXISTS (SELECT 1 FROM hits hx WHERE hx.user_id = u.id AND hx.source_type IN ('post', 'engagement') AND ("
                for (i, o) in shown.enumerated() { clause = clause + (i == 0 ? "" : " OR ") + o }
                clause = clause + ")))"
                wheres.append(clause)
            }
        }
        if let g = p.targetGender {
            wheres.append("u.gender = \(bind: g)")
        } else if p.hasDatingIntent, let cg = p.currentUserGender {
            let opp = cg == "male" ? "female" : (cg == "female" ? "male" : "other")
            wheres.append("u.gender = \(bind: opp)")
        }
        if p.targetAgeMin != nil || p.targetAgeMax != nil {
            wheres.append("u.age IS NOT NULL")
            if let mn = p.targetAgeMin { wheres.append("u.age >= \(bind: mn)") }
            if let mx = p.targetAgeMax { wheres.append("u.age <= \(bind: mx)") }
        }

        var userFilter: SQLQueryString = ""
        if !wheres.isEmpty {
            userFilter = "WHERE "
            for (i, w) in wheres.enumerated() { userFilter = userFilter + (i == 0 ? "" : " AND ") + w }
        }

        // ── mutual_count ──
        var mutualSelect: SQLQueryString = "0"
        if let sid = p.excludeUserID {
            let modeFilter: SQLQueryString = p.mode.map { "AND cm.mode = \(bind: $0)" } ?? ""
            let modeFilter2: SQLQueryString = p.mode.map { "AND cm2.mode = \(bind: $0)" } ?? ""
            mutualSelect = """
                (SELECT COUNT(*)::int FROM (
                  SELECT CASE WHEN cm.requester_id = \(uuid: sid) THEN cm.addressee_id ELSE cm.requester_id END
                  FROM connections cm WHERE cm.status = 'accepted' \(modeFilter)
                    AND (cm.requester_id = \(uuid: sid) OR cm.addressee_id = \(uuid: sid))
                  INTERSECT
                  SELECT CASE WHEN cm2.requester_id = u.id THEN cm2.addressee_id ELSE cm2.requester_id END
                  FROM connections cm2 WHERE cm2.status = 'accepted' \(modeFilter2)
                    AND (cm2.requester_id = u.id OR cm2.addressee_id = u.id)
                ) mutual)
                """
        }

        // ── persona identity columns ──
        let identityCols: SQLQueryString = p.mode.map { m in
            """
            (CASE WHEN \(bind: m) = 'work' THEN u.work_display_name ELSE u.hobby_display_name END) AS display_name,
            (CASE WHEN \(bind: m) = 'work' THEN u.work_bio ELSE u.hobby_bio END) AS bio,
            (CASE WHEN \(bind: m) = 'work' THEN u.work_avatar_url ELSE u.hobby_avatar_url END) AS avatar_url,
            (CASE WHEN \(bind: m) = 'work' THEN u.work_cover_url ELSE u.hobby_cover_url END) AS cover_url
            """
        } ?? "u.display_name, u.bio, u.avatar_url, u.cover_url"

        let searcherRef: SQLQueryString = p.excludeUserID.map { "\(uuid: $0)" } ?? "NULL"

        var sql: SQLQueryString = "WITH chunk_pool AS (" + pool + "),\n"
        sql = sql + """
            authored AS (
              SELECT user_id, source_type, source_id, topic, content, sim
              FROM chunk_pool WHERE sim >= \(bind: p.threshold)
            ),
            engaged AS (
              -- Everyone who reacted to a matching post (not its author), once
              -- per post at their strongest reaction's weight.
              SELECT r.user_id, h.source_id, h.topic, h.content,
                     h.sim * MAX(CASE WHEN r.kind = 'like' THEN \(bind: wReactLike)::float8
                                      ELSE \(bind: wReactCommentOrShare)::float8 END) AS sim,
                     bool_or(r.kind = 'comment' AND r.is_public) AS commented,
                     bool_or(r.kind = 'share' AND r.is_public) AS shared
              FROM authored h
              JOIN post_reactions r ON r.post_id = h.source_id
              WHERE h.source_type = 'post' AND r.user_id <> h.user_id
              GROUP BY r.user_id, h.source_id, h.topic, h.content, h.sim
            ),
            hits AS (
              -- Authored and reaction hits rank together, so several reactions
              -- add up through the top-3 average.
              SELECT user_id, source_type, source_id, topic, content, sim,
                     ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY sim DESC) AS rn
              FROM (
                SELECT user_id, source_type, source_id, topic, content, sim FROM authored
                UNION ALL
                SELECT user_id, 'engagement', source_id, topic, content, sim FROM engaged
              ) combined
            ),
            user_scores AS (
              SELECT user_id,
                     (\(unsafeRaw: String(wMax)) * MAX(sim)
                    + \(unsafeRaw: String(wAvg)) * (SUM(sim) FILTER (WHERE rn <= 3) / 3.0))::float AS retrieval_score
              FROM hits GROUP BY user_id
            ),
            evidence AS (
              SELECT user_id, jsonb_agg(ev ORDER BY sim DESC) AS match_evidence
              FROM (
                SELECT h.user_id, h.sim,
                       jsonb_build_object('source_type', h.source_type, 'topic', h.topic,
                         'content', h.content, 'similarity', ROUND(h.sim::numeric, 4)) AS ev
                FROM hits h WHERE h.source_type = 'user_profile'
                UNION ALL
                SELECT h.user_id, MAX(h.sim) AS sim,
                       jsonb_build_object('source_type', 'post', 'topic', h.topic,
                         'content', string_agg(h.content, ' '),
                         'similarity', ROUND(MAX(h.sim)::numeric, 4),
                         'post_count', COUNT(*),
                         'latest_post_at', MAX(p2.created_at),
                         'oldest_post_at', MIN(p2.created_at)) AS ev
                FROM hits h JOIN posts p2 ON p2.id = h.source_id
                WHERE h.source_type = 'post' AND p2.status = 'posted' AND p2.privacy = 'public'
                GROUP BY h.user_id, h.topic
                UNION ALL
                SELECT e.user_id, MAX(e.sim) AS sim,
                       jsonb_build_object('source_type', 'engagement', 'topic', e.topic,
                         'content', string_agg(e.content, ' '),
                         'similarity', ROUND(MAX(e.sim)::numeric, 4),
                         'commented_count', COUNT(*) FILTER (WHERE e.commented),
                         'shared_count', COUNT(*) FILTER (WHERE e.shared)) AS ev
                FROM engaged e
                GROUP BY e.user_id, e.topic
              ) grouped
              GROUP BY user_id
            ),
            personal AS (
              SELECT pc.user_id,
                     (1 - (pc.embedding <=> (
                        SELECT embedding FROM user_embedding_chunks
                        WHERE user_id = \(searcherRef)::uuid AND source_type = 'user_profile' LIMIT 1
                     )))::float AS profile_sim
              FROM user_embedding_chunks pc
              WHERE pc.source_type = 'user_profile' AND pc.user_id IN (SELECT user_id FROM user_scores)
            )
            SELECT u.id::text AS id, u.username,
            """
        sql = sql + identityCols + ",\n"
        sql = sql + """
              u.avatar_color, u.location, u.job_title, u.company, u.default_mode, u.gender,
              CASE WHEN u.dob_visibility = 'public' THEN u.age ELSE NULL END AS age,
              u.follower_count, u.following_count, u.post_count,
              COALESCE(json_agg(DISTINCT ui2.interest) FILTER (WHERE ui2.interest IS NOT NULL), '[]')::text AS interests,
              COALESCE(json_agg(DISTINCT us2.skill) FILTER (WHERE us2.skill IS NOT NULL), '[]')::text AS skills,
              COALESCE(\(unsafeRaw: String(wRetrieval)) * s.retrieval_score + \(unsafeRaw: String(wPersonal)) * pr.profile_sim,
                       s.retrieval_score)::float AS score,
              COALESCE(e.match_evidence, '[]'::jsonb)::text AS match_evidence,
            """
        sql = sql + mutualSelect + " AS mutual_count\n"
        sql = sql + """
            FROM user_scores s
            JOIN users u ON u.id = s.user_id
            LEFT JOIN evidence e ON e.user_id = s.user_id
            LEFT JOIN personal pr ON pr.user_id = s.user_id
            LEFT JOIN user_interests ui2 ON ui2.user_id = u.id
            LEFT JOIN user_skills us2 ON us2.user_id = u.id
            """
        sql = sql + "\n" + userFilter + "\n"
        sql = sql + "GROUP BY u.id, s.retrieval_score, pr.profile_sim, e.match_evidence ORDER BY score DESC LIMIT 20"

        return try await db.raw(sql).all(decoding: RawUser.self)
    }
}

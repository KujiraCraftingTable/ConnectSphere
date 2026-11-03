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
    static let wMax = 0.7, wAvg = 0.3
    /// Reacting to a matching post is evidence of interest, but weaker than
    /// writing about it: a reactor is credited the post's match × this weight.
    /// A comment or share takes more effort than a like.
    static let wReactLike = 0.8, wReactCommentOrShare = 0.9
    static let evidencePerUser = 5
    static let highConfidenceThreshold = 0.8
    static let suggestThreshold = 0.6
    /// Interest groups the LLM pulls out of a prompt lift the people who match
    /// them (scaled by the share of groups matched) rather than exclude everyone
    /// else — one invented group ("walks") used to empty the whole result.
    static let wGroup = 0.1
    /// A display name or username at least this close (pg_trgm
    /// `strict_word_similarity`, accents folded) to some words of the prompt
    /// is a name match: "tìm Lý Thảo" → @lythao.
    static let nameMatchMin = 0.6

    static func vecLiteral(_ v: [Double]) -> String {
        "[" + v.map { String($0) }.joined(separator: ",") + "]"
    }

    // MARK: topic gate (AI_SEARCH_REVIEW.md, phase S6)

    /// The gate's text check: the exact words or phrases, unstemmed. Stemmed,
    /// "chatting" is "chat" and any "let's chat about it" post would count as
    /// the Chatting hobby; the catalogue lists the word forms that matter.
    static func exactText(_ terms: [String]) -> SQLQueryString {
        guard !terms.isEmpty else { return "false" }
        var q: SQLQueryString = "(to_tsvector('simple', COALESCE(c.content, '')) @@ ("
        for (i, t) in terms.enumerated() {
            q = q + (i == 0 ? "" : " || ") + "phraseto_tsquery('simple', \(bind: t))"
        }
        return q + "))"
    }

    /// Everyone who shows topic `c`: picked it (or something under it) as an
    /// interest or skill, wrote its exact words in their profile or a public post,
    /// or posted about it (a post chunk within `conceptPostMin` of the topic
    /// embedded on its own). Reacting to such a post doesn't count here — it
    /// ranks, but it doesn't prove interest.
    static func conceptPeople(_ c: SearchConcepts.Concept, vector: [Double]?, mode: String?,
                              on db: any SQLDatabase) async throws -> Set<String> {
        let postMode: SQLQueryString = mode.map { "AND pp.mode = \(bind: $0)" } ?? ""
        var q: SQLQueryString = """
            SELECT ui.user_id::text AS id FROM user_interests ui
            WHERE LOWER(split_part(ui.interest, ' · ', 1)) = ANY(\(bind: c.declared)::text[])
               OR LOWER(split_part(ui.interest, ' · ', 2)) = ANY(\(bind: c.declared)::text[])
            UNION
            SELECT us.user_id::text FROM user_skills us WHERE LOWER(us.skill) = ANY(\(bind: c.declared)::text[])
            UNION
            SELECT c.user_id::text FROM user_embedding_chunks c
            WHERE \(exactText(c.terms))
              AND (c.source_type = 'user_profile'
                   OR EXISTS (SELECT 1 FROM posts pp WHERE pp.id = c.source_id
                              AND pp.status = 'posted' AND pp.privacy = 'public' \(postMode)))
            """
        if let v = vector {
            q = q + """
                 UNION
                SELECT c.user_id::text FROM user_embedding_chunks c JOIN posts pp ON pp.id = c.source_id
                WHERE c.source_type = 'post' AND pp.status = 'posted' AND pp.privacy = 'public' \(postMode)
                  AND (1 - (c.embedding <=> \(bind: vecLiteral(v))::vector)) >= \(bind: SearchConcepts.conceptPostMin)
                """
        }
        struct R: Decodable { let id: String }
        return Set(try await db.raw(q).all(decoding: R.self).map(\.id))
    }

    struct PostHit: Decodable { let id: String; let sim: Double }

    /// Posted posts in `mode` about topic `c`: its words in the text, or the
    /// chunk within `conceptPostMin` of the topic. `sim` is how close the post
    /// is to the topic (0 without a vector). Visibility (privacy, blocks,
    /// communities, hidden, muted) is deliberately not checked here: callers
    /// hydrate through `PostStore.findVisible`, which applies the feed's own
    /// rules, so the two can't drift apart.
    static func conceptPosts(_ c: SearchConcepts.Concept, vector: [Double]?, mode: String?,
                             on db: any SQLDatabase) async throws -> [PostHit] {
        let sim: SQLQueryString = vector.map { "(1 - (c.embedding <=> \(bind: vecLiteral($0))::vector))::float" } ?? "0::float"
        var q: SQLQueryString = "SELECT c.source_id::text AS id, MAX(" + sim + """
            ) AS sim
            FROM user_embedding_chunks c JOIN posts p ON p.id = c.source_id
            WHERE c.source_type = 'post' AND p.status = 'posted'
            """
        if let m = mode { q = q + " AND p.mode = \(bind: m)" }
        q = q + " AND (" + exactText(c.terms)
        if vector != nil { q = q + " OR " + sim + " >= \(bind: SearchConcepts.conceptPostMin)" }
        q = q + ") GROUP BY c.source_id"
        return try await db.raw(q).all(decoding: PostHit.self)
    }

    // MARK: getUserContext / logSearch

    struct UserContext: Decodable { let gender: String?; let location: String?; let age: Int? }
    static func getUserContext(_ userID: String, on db: any SQLDatabase) async throws -> UserContext? {
        try await db.raw("SELECT gender, location, age FROM users WHERE id = \(uuid: userID)").first(decoding: UserContext.self)
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
        var searchLat: Double?
        var searchLng: Double?
        var radiusKm: Double?
        var threshold = 0.6
        var excludeUserID: String?
        var interestGroups: [[String]]?
        /// Set → only these people (those who matched every topic the prompt
        /// names, phase S6).
        var allowedUsers: [String]?
        /// Set → the keyword leg: full-text over chunk text instead of the
        /// vector, plus name matching. `queryVector` and `threshold` are unused.
        var keyword: KeywordQuery?
    }

    struct KeywordQuery {
        /// Criteria terms (interests, skills, entity…), already in English.
        var terms: [String]
        /// The prompt as typed — names are matched against it.
        var nameQuery: String
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
        /// The leg's own match (vector or keyword), before the group lift.
        var retrieval: Double
        /// 0 unless the keyword leg matched this person's name.
        var name_match: Double
        var match_evidence: String                  // ::text jsonb
        var mutual_count: Int
    }

    private static func jsNorm(_ s: String) -> String {
        s.lowercased()
            .replacingOccurrences(of: " city", with: "")
            .replacingOccurrences(of: " province", with: "")
            .replacingOccurrences(of: " ", with: "")
    }

    /// Any of the terms, each read as a web-style query ("iOS developer" →
    /// io & develop). No terms → NULL, which matches nothing.
    static func tsQuery(_ terms: [String]) -> SQLQueryString {
        guard !terms.isEmpty else { return "NULL::tsquery" }
        var q: SQLQueryString = "("
        for (i, t) in terms.enumerated() {
            q = q + (i == 0 ? "" : " || ") + "websearch_to_tsquery('english', \(bind: t))"
        }
        return q + ")"
    }

    static func vectorSearch(_ p: Params, on db: any SQLDatabase) async throws -> [RawUser] {
        let lit = vecLiteral(p.queryVector)
        let isKeyword = p.keyword != nil
        let tsq = tsQuery(p.keyword?.terms ?? [])

        // ── chunk_pool (folded fix: pre-filter before the HNSW LIMIT) ──
        // Keyword leg: `sim` is ts_rank_cd normalised to 0…1 (rank / (rank+1)) —
        // only comparable within this leg; the legs meet by rank (RRF), not score.
        let simExpr: SQLQueryString = isKeyword
            ? "ts_rank_cd(c.search_tsv, \(tsq), 32)::float"
            : "(1 - (c.embedding <=> \(bind: lit)::vector))::float"
        var pool: SQLQueryString = "SELECT c.user_id, c.source_type, c.source_id, c.topic, c.content, "
        pool = pool + simExpr + """
             AS sim
            FROM user_embedding_chunks c
            JOIN users a ON a.id = c.user_id AND a.deleted_at IS NULL
            WHERE
            """
        if isKeyword { pool = pool + " c.search_tsv @@ " + tsq + " AND" }
        pool = pool + """
             (c.source_type = 'user_profile'
                   OR EXISTS (SELECT 1 FROM posts pp WHERE pp.id = c.source_id
                              AND pp.status = 'posted' AND pp.privacy = 'public'
            """
        // Hobby and Work are separate worlds: a post only counts as evidence
        // (for its author, or for anyone who reacted to it) in its own mode.
        if let m = p.mode { pool = pool + " AND pp.mode = \(bind: m)" }
        pool = pool + "))"
        if let ids = p.allowedUsers { pool = pool + " AND c.user_id::text = ANY(\(bind: ids)::text[])" }
        if let sid = p.excludeUserID {
            pool = pool + """
                 AND NOT EXISTS (SELECT 1 FROM user_blocks ub
                   WHERE (ub.blocker_id = \(uuid: sid) AND ub.blocked_id = c.user_id)
                      OR (ub.blocker_id = c.user_id AND ub.blocked_id = \(uuid: sid)))
                """
        }
        pool = pool + (isKeyword ? " ORDER BY sim DESC" : " ORDER BY c.embedding <=> \(bind: lit)::vector")
            + " LIMIT \(unsafeRaw: String(chunkPoolSize))"

        // ── user-level hard filters (setup clause inlined with the bound mode) ──
        // Reactors can be any user, not just chunk owners from the pool.
        var wheres: [SQLQueryString] = ["u.deleted_at IS NULL"]
        if let ids = p.allowedUsers { wheres.append("u.id::text = ANY(\(bind: ids)::text[])") }
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
        // Share of interest groups this person matches (0…1), lifting the score
        // by `wGroup` — see `wGroup` for why it no longer filters.
        var groupMatch: SQLQueryString = "0"
        if let groups = p.interestGroups?.filter({ !$0.isEmpty }), !groups.isEmpty {
            groupMatch = "(("
            for (gi, group) in groups.enumerated() {
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
                groupMatch = groupMatch + (gi == 0 ? "" : " + ") + "(CASE WHEN " + clause + " THEN 1 ELSE 0 END)"
            }
            groupMatch = groupMatch + ")::float / \(unsafeRaw: String(groups.count)))"
        }
        if let g = p.targetGender {
            wheres.append("u.gender = \(bind: g)")
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

        // ── names: people whose name appears in the prompt (keyword leg only) ──
        var names: SQLQueryString = "SELECT NULL::uuid AS user_id, 0::float AS name_sim WHERE false"
        if let q = p.keyword?.nameQuery, !q.isEmpty {
            let nameCol = p.mode == "work" ? "u.work_display_name" : (p.mode == "hobby" ? "u.hobby_display_name" : "u.display_name")
            let nameSim: SQLQueryString = """
                GREATEST(
                  strict_word_similarity(unaccent(lower(COALESCE(\(unsafeRaw: nameCol), ''))), unaccent(lower(\(bind: q)))),
                  strict_word_similarity(lower(u.username), lower(\(bind: q))))
                """
            names = "SELECT u.id AS user_id, " + nameSim + "::float AS name_sim FROM users u WHERE u.deleted_at IS NULL AND "
                + nameSim + " >= \(unsafeRaw: String(nameMatchMin))"
        }

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
            text_scores AS (
              SELECT user_id,
                     (\(unsafeRaw: String(wMax)) * MAX(sim)
                    + \(unsafeRaw: String(wAvg)) * (SUM(sim) FILTER (WHERE rn <= 3) / 3.0))::float AS retrieval_score
              FROM hits GROUP BY user_id
            ),
            names AS (\(names)),
            user_scores AS (
              SELECT COALESCE(t.user_id, n.user_id) AS user_id,
                     COALESCE(t.retrieval_score, 0)::float AS retrieval_score,
                     COALESCE(n.name_sim, 0)::float AS name_match
              FROM text_scores t FULL JOIN names n ON n.user_id = t.user_id
            ),
            evidence AS (
              SELECT user_id, jsonb_agg(ev ORDER BY sim DESC) AS match_evidence
              FROM (
                SELECT h.user_id, h.sim,
                       jsonb_build_object('source_type', h.source_type, 'topic', h.topic,
                         'content', h.content, 'similarity', \(unsafeRaw: isKeyword ? "NULL" : "ROUND(h.sim::numeric, 4)")) AS ev
                FROM hits h WHERE h.source_type = 'user_profile'
                UNION ALL
                SELECT h.user_id, MAX(h.sim) AS sim,
                       jsonb_build_object('source_type', 'post', 'topic', h.topic,
                         'content', string_agg(h.content, ' '),
                         'similarity', \(unsafeRaw: isKeyword ? "NULL" : "ROUND(MAX(h.sim)::numeric, 4)"),
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
                         'similarity', \(unsafeRaw: isKeyword ? "NULL" : "ROUND(MAX(e.sim)::numeric, 4)"),
                         'commented_count', COUNT(*) FILTER (WHERE e.commented),
                         'shared_count', COUNT(*) FILTER (WHERE e.shared)) AS ev
                FROM engaged e
                GROUP BY e.user_id, e.topic
              ) grouped
              GROUP BY user_id
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
              (s.retrieval_score + \(unsafeRaw: String(wGroup)) * \(groupMatch))::float AS score,
              s.retrieval_score AS retrieval, s.name_match,
              COALESCE(e.match_evidence, '[]'::jsonb)::text AS match_evidence,
            """
        sql = sql + mutualSelect + " AS mutual_count\n"
        sql = sql + """
            FROM user_scores s
            JOIN users u ON u.id = s.user_id
            LEFT JOIN evidence e ON e.user_id = s.user_id
            LEFT JOIN user_interests ui2 ON ui2.user_id = u.id
            LEFT JOIN user_skills us2 ON us2.user_id = u.id
            """
        sql = sql + "\n" + userFilter + "\n"
        // Name matches first: someone who typed a person's name wants that person.
        sql = sql + "GROUP BY u.id, s.retrieval_score, s.name_match, e.match_evidence ORDER BY s.name_match DESC, score DESC LIMIT 20"

        return try await db.raw(sql).all(decoding: RawUser.self)
    }
}

// MARK: - Ranking features and search sessions (AI_SEARCH_REVIEW.md, S2–S4)

extension SearchStore {
    /// Your taste for people search: the feed's taste vectors (profile plus
    /// what you engage with) and the profiles of people you connected with
    /// from a search lately. Empty when there's nothing to go on.
    static func searchTaste(_ userID: String, on db: any SQLDatabase) async throws -> [[Double]] {
        struct V: Decodable { let vec: String }
        let connected = try await db.raw("""
            SELECT c.embedding::text AS vec
            FROM search_results r
            JOIN search_sessions s ON s.id = r.session_id
            JOIN user_embedding_chunks c ON c.user_id = r.shown_user_id AND c.source_type = 'user_profile'
            WHERE s.user_id = \(uuid: userID) AND r.connected_at IS NOT NULL
              AND r.connected_at > NOW() - INTERVAL '\(unsafeRaw: String(SearchRanking.connectedTasteDays)) days'
            ORDER BY r.connected_at DESC LIMIT \(unsafeRaw: String(SearchRanking.maxConnectedTastes))
            """).all(decoding: V.self).map { FeedStore.normalize(FeedStore.parseVec($0.vec)) }
        return (try await FeedStore.buildTasteVectors(userID, on: db) ?? []) + connected
    }

    /// A person's profile embedding ("More like @x").
    static func profileVector(_ userID: String, on db: any SQLDatabase) async throws -> [Double]? {
        struct V: Decodable { let vec: String }
        return try await db.raw("""
            SELECT embedding::text AS vec FROM user_embedding_chunks
            WHERE user_id = \(uuid: userID) AND source_type = 'user_profile' LIMIT 1
            """).first(decoding: V.self).map { FeedStore.parseVec($0.vec) }
    }

    /// Everything `SearchRanking.rerank` needs about each candidate, in one query.
    static func rankFeatures(searcher: String, candidates: [String], tastes: [[Double]], mode: String?,
                             on db: any SQLDatabase) async throws -> [String: SearchRanking.Features] {
        guard !candidates.isEmpty else { return [:] }
        let modeFilter: SQLQueryString = mode.map { " AND pp.mode = \(bind: $0)" } ?? ""
        let dismissSince: SQLQueryString = "NOW() - INTERVAL '\(unsafeRaw: String(SearchRanking.dismissDays)) days'"
        var sql: SQLQueryString = """
            WITH cand AS (SELECT DISTINCT unnest(\(bind: candidates)::uuid[]) AS user_id),
            t AS (SELECT v::vector AS vec FROM unnest(\(bind: tastes.map(vecLiteral))::text[]) v),
            ch AS (
              SELECT c.user_id, c.embedding FROM user_embedding_chunks c
              WHERE c.user_id IN (SELECT user_id FROM cand)
                AND (c.source_type = 'user_profile'
                     OR EXISTS (SELECT 1 FROM posts pp WHERE pp.id = c.source_id
                                AND pp.status = 'posted' AND pp.privacy = 'public'
            """
        sql = sql + modeFilter + """
            ))
            ),
            taste AS (
              SELECT ch.user_id, MAX(1 - (ch.embedding <=> t.vec))::float AS taste
              FROM ch CROSS JOIN t GROUP BY ch.user_id
            ),
            dismissed AS (
              SELECT DISTINCT r.shown_user_id AS user_id FROM search_results r
              JOIN search_sessions s ON s.id = r.session_id
              WHERE s.user_id = \(uuid: searcher) AND r.dismissed_at > \(dismissSince)
            )
            SELECT cand.user_id::text AS user_id,
                   ta.taste,
                   (SELECT COUNT(*)::int FROM community_members a
                      JOIN community_members b ON b.community_id = a.community_id
                     WHERE a.user_id = \(uuid: searcher) AND b.user_id = cand.user_id) AS shared_communities,
                   (EXTRACT(EPOCH FROM NOW() - GREATEST(
                      (SELECT MAX(created_at) FROM posts WHERE author_id = cand.user_id AND status = 'posted'),
                      (SELECT MAX(created_at) FROM comments WHERE author_id = cand.user_id AND status <> 'deleted'),
                      (SELECT MAX(last_seen_at) FROM post_impressions WHERE user_id = cand.user_id)
                   )) / 86400.0)::float AS active_days_ago,
                   EXISTS (SELECT 1 FROM dismissed d WHERE d.user_id = cand.user_id) AS dismissed,
                   (SELECT MAX(1 - (cp.embedding <=> dp.embedding))::float
                      FROM user_embedding_chunks cp
                      JOIN dismissed d ON d.user_id <> cand.user_id
                      JOIN user_embedding_chunks dp ON dp.user_id = d.user_id AND dp.source_type = 'user_profile'
                     WHERE cp.user_id = cand.user_id AND cp.source_type = 'user_profile') AS dismissed_like
            FROM cand LEFT JOIN taste ta ON ta.user_id = cand.user_id
            """
        let rows = try await db.raw(sql).all(decoding: SearchRanking.Features.self)
        return Dictionary(rows.map { ($0.user_id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    struct PostFeatures: Decodable {
        let id: String; let taste: Double?; let seen_hours_ago: Double?
        let less_similar: Bool; let less_author: Bool; let more_similar: Bool; let more_author: Bool
    }

    /// Your taste, what you've seen and your feed feedback for each post hit
    /// (AI post search, phase S5).
    static func postFeatures(viewer: String, postIDs: [String], tastes: [[Double]],
                             on db: any SQLDatabase) async throws -> [String: PostFeatures] {
        guard !postIDs.isEmpty else { return [:] }
        let since: SQLQueryString = "NOW() - INTERVAL '\(unsafeRaw: String(FeedStore.feedbackDays)) days'"
        let similar: SQLQueryString = "(c.embedding <=> fc.embedding) <= \(unsafeRaw: String(FeedStore.similarDistance))"
        func fb(_ kind: String, similarPosts: Bool) -> SQLQueryString {
            similarPosts
                ? "EXISTS (SELECT 1 FROM post_feedback f JOIN user_embedding_chunks fc ON fc.source_type = 'post' AND fc.source_id = f.post_id WHERE f.user_id = \(uuid: viewer) AND f.kind = \(bind: kind) AND f.created_at > \(since) AND \(similar))"
                : "EXISTS (SELECT 1 FROM post_feedback f WHERE f.user_id = \(uuid: viewer) AND f.kind = \(bind: kind) AND f.created_at > \(since) AND f.author_id = p.author_id)"
        }
        let sql: SQLQueryString = """
            WITH t AS (SELECT v::vector AS vec FROM unnest(\(bind: tastes.map(vecLiteral))::text[]) v)
            SELECT p.id::text AS id,
                   (SELECT MAX(1 - (c.embedding <=> t.vec)) FROM t)::float AS taste,
                   (SELECT EXTRACT(EPOCH FROM NOW() - pi.first_seen_at) / 3600.0 FROM post_impressions pi
                     WHERE pi.user_id = \(uuid: viewer) AND pi.post_id = p.id)::float AS seen_hours_ago,
                   \(fb("less", similarPosts: true)) AS less_similar,
                   \(fb("less", similarPosts: false)) AS less_author,
                   \(fb("more", similarPosts: true)) AS more_similar,
                   \(fb("more", similarPosts: false)) AS more_author
            FROM posts p
            JOIN LATERAL (SELECT embedding FROM user_embedding_chunks
                          WHERE source_type = 'post' AND source_id = p.id LIMIT 1) c ON true
            WHERE p.id = ANY(\(bind: postIDs)::uuid[])
            """
        return Dictionary(try await db.raw(sql).all(decoding: PostFeatures.self).map { ($0.id, $0) },
                          uniquingKeysWith: { a, _ in a })
    }

    // MARK: sessions (phase S3)

    struct Session: Decodable {
        let id: String; let query: String; let mode: String?; let criteria: String; let explanations: String?
    }

    /// Records a search and who it showed, in order. Returns the session id.
    static func recordSession(userID: String, query: String, mode: String?, criteriaJSON: String,
                              shown: [(id: String, score: Double)], on db: any SQLDatabase) async throws -> String {
        struct R: Decodable { let id: String }
        let sid = try await db.raw("""
            INSERT INTO search_sessions (user_id, query, mode, criteria)
            VALUES (\(uuid: userID), \(bind: query), \(bind: mode), \(bind: criteriaJSON)::jsonb)
            RETURNING id::text AS id
            """).first(decoding: R.self)!.id
        if !shown.isEmpty {
            try await db.raw("""
                INSERT INTO search_results (session_id, shown_user_id, rank, score)
                SELECT \(uuid: sid), u, r::int, s
                FROM unnest(\(bind: shown.map(\.id))::uuid[], \(bind: shown.map(\.score))::float8[])
                     WITH ORDINALITY AS x(u, s, r)
                ON CONFLICT DO NOTHING
                """).run()
        }
        return sid
    }

    /// Your own session, or nil (someone else's id is treated as unknown).
    static func session(_ id: String, userID: String, on db: any SQLDatabase) async throws -> Session? {
        try await db.raw("""
            SELECT id::text AS id, query, mode, criteria::text AS criteria, explanations::text AS explanations
            FROM search_sessions WHERE id = \(uuid: id) AND user_id = \(uuid: userID)
            """).first(decoding: Session.self)
    }

    static let eventColumns = ["tap": "tapped_at", "dismiss": "dismissed_at"]

    /// Stamps a tap or "Not a fit" on someone a session of yours showed.
    /// False when that person wasn't in it.
    static func stampEvent(sessionID: String, userID: String, shownUserID: String, kind: String,
                           on db: any SQLDatabase) async throws -> Bool {
        guard let col = eventColumns[kind] else { return false }
        struct R: Decodable { let n: Int }
        let n = try await db.raw("""
            WITH u AS (
              UPDATE search_results r SET \(unsafeRaw: col) = COALESCE(r.\(unsafeRaw: col), NOW())
              FROM search_sessions s
              WHERE s.id = r.session_id AND s.id = \(uuid: sessionID) AND s.user_id = \(uuid: userID)
                AND r.shown_user_id = \(uuid: shownUserID)
              RETURNING 1)
            SELECT COUNT(*)::int AS n FROM u
            """).first(decoding: R.self)?.n ?? 0
        return n > 0
    }

    /// Credits a connection request or first message to the latest search in
    /// the last week that showed that person, so the app needn't pass the
    /// session around.
    static func creditOutcome(from userID: String, to otherID: String, column: String,
                              on db: any SQLDatabase) async throws {
        guard ["connected_at", "messaged_at"].contains(column) else { return }
        try await db.raw("""
            UPDATE search_results r SET \(unsafeRaw: column) = NOW()
            WHERE (r.session_id, r.shown_user_id) = (
              SELECT r2.session_id, r2.shown_user_id FROM search_results r2
              JOIN search_sessions s ON s.id = r2.session_id
              WHERE s.user_id = \(uuid: userID) AND r2.shown_user_id = \(uuid: otherID)
                AND s.created_at > NOW() - INTERVAL '7 days'
              ORDER BY s.created_at DESC LIMIT 1)
              AND r.\(unsafeRaw: column) IS NULL
            """).run()
    }

    /// What the top people of a session say about themselves — their profile
    /// and latest public posts — for "why they fit you". Only text anyone can
    /// already see on their profile.
    static func explainEvidence(sessionID: String, top: Int, mode: String?,
                                on db: any SQLDatabase) async throws -> [OllamaService.ExplainPerson] {
        struct R: Decodable { let id: String; let texts: [String] }
        let modeFilter: SQLQueryString = mode.map { " AND pp.mode = \(bind: $0)" } ?? ""
        var sql: SQLQueryString = """
            SELECT r.shown_user_id::text AS id,
                   ARRAY(SELECT LEFT(c.content, 300) FROM user_embedding_chunks c
                         WHERE c.user_id = r.shown_user_id AND c.content IS NOT NULL
                           AND (c.source_type = 'user_profile'
                                OR EXISTS (SELECT 1 FROM posts pp WHERE pp.id = c.source_id
                                           AND pp.status = 'posted' AND pp.privacy = 'public'
            """
        sql = sql + modeFilter + """
            ))
                         ORDER BY (c.source_type = 'user_profile') DESC, c.created_at DESC LIMIT 3) AS texts
            FROM search_results r
            WHERE r.session_id = \(uuid: sessionID)
            ORDER BY r.rank LIMIT \(bind: top)
            """
        return try await db.raw(sql).all(decoding: R.self).map { .init(id: $0.id, evidence: $0.texts) }
    }

    /// Your interests and skills, for "why they fit you".
    static func interestsOf(_ userID: String, on db: any SQLDatabase) async throws -> [String] {
        struct R: Decodable { let t: String }
        return try await db.raw("""
            SELECT interest AS t FROM user_interests WHERE user_id = \(uuid: userID)
            UNION SELECT skill FROM user_skills WHERE user_id = \(uuid: userID)
            LIMIT 30
            """).all(decoding: R.self).map(\.t)
    }

    static func saveExplanations(sessionID: String, json: String, on db: any SQLDatabase) async throws {
        try await db.raw("UPDATE search_sessions SET explanations = \(bind: json)::jsonb WHERE id = \(uuid: sessionID)").run()
    }

    struct Metrics: Decodable {
        let searches: Int; let zero_result: Int; let top5_tap_rate: Double?; let connect_rate: Double?
    }

    /// Last week's search health, for the daily log line.
    static func weeklyMetrics(on db: any SQLDatabase) async throws -> Metrics? {
        try await db.raw("""
            WITH s AS (SELECT id FROM search_sessions WHERE created_at > NOW() - INTERVAL '7 days'),
            per AS (
              SELECT s.id,
                     COUNT(r.shown_user_id) AS shown,
                     bool_or(r.tapped_at IS NOT NULL AND r.rank <= 5) AS top5_tap,
                     bool_or(r.connected_at IS NOT NULL) AS connected
              FROM s LEFT JOIN search_results r ON r.session_id = s.id GROUP BY s.id)
            SELECT COUNT(*)::int AS searches,
                   COUNT(*) FILTER (WHERE shown = 0)::int AS zero_result,
                   (AVG(CASE WHEN top5_tap THEN 1.0 ELSE 0.0 END) FILTER (WHERE shown > 0))::float AS top5_tap_rate,
                   (AVG(CASE WHEN connected THEN 1.0 ELSE 0.0 END) FILTER (WHERE shown > 0))::float AS connect_rate
            FROM per
            """).first(decoding: Metrics.self)
    }
}

import Vapor
import SQLKit

/// People you may know (migration 044). Candidates are friends of your
/// friends plus the people whose profile embedding is closest to yours, all in
/// one mode; SQL filters out anyone who can't be suggested, Swift scores and
/// explains the rest (`score` / `reason` are pure, so they're unit-tested).
enum SuggestionStore {
    static let modes: Set<String> = ["hobby", "work"]
    static let defaultLimit = 20
    static let maxLimit = 50
    /// How many nearest profiles join the pool, and how many candidates get
    /// scored — bounded so the query stays cheap however big the graph gets.
    static let nearestProfiles = 100
    static let poolLimit = 300

    struct Reason: Content {
        /// mutual | interest | skill | company | place | similar
        var kind: String
        @NullCoded var value: String?
        @NullCoded var count: Int?
    }

    struct Suggestion: Content {
        var id: String
        var username: String
        var display_name: String
        @NullCoded var avatar_url: String?
        @NullCoded var avatar_color: String?
        @NullCoded var job_title: String?
        @NullCoded var company: String?
        @NullCoded var bio: String?
        @NullCoded var location: String?
        /// Their interests (Hobby) or skills (Work).
        var tags: [String]
        var mutual_count: Int
        /// How closely the two profiles match, as AI search measures it
        /// (cosine of the profile embeddings × 100); null without an embedding.
        @NullCoded var match_percent: Int?
        var reason: Reason
    }

    /// One scored candidate as SQL returns it.
    struct Row: Decodable {
        let id: String
        let username: String
        let display_name: String
        let avatar_url: String?
        let avatar_color: String?
        let job_title: String?
        let company: String?
        let bio: String?
        let location: String?
        let tags: [String]
        let mutual_count: Int
        let similarity: Double?
        let shared: [String]
        let same_company: String?
        let same_province: String?
    }

    /// 0…1. Mutual friends weigh most (you likely know them), then how alike
    /// the profiles read, then shared interests/skills, then same place.
    static func score(mutual: Int, similarity: Double?, shared: Int, samePlace: Bool) -> Double {
        0.4 * Double(min(mutual, 5)) / 5
            + 0.35 * max(0, similarity ?? 0)
            + 0.15 * Double(min(shared, 3)) / 3
            + (samePlace ? 0.1 : 0)
    }

    /// The one line shown on the card — the strongest true thing about them.
    static func reason(mode: String, mutual: Int, shared: [String], sameCompany: String?, sameProvince: String?) -> Reason {
        if mutual > 0 { return Reason(kind: "mutual", value: nil, count: mutual) }
        if let first = shared.first { return Reason(kind: mode == "work" ? "skill" : "interest", value: first, count: nil) }
        if mode == "work", let company = sameCompany { return Reason(kind: "company", value: company, count: nil) }
        if let province = sameProvince { return Reason(kind: "place", value: province, count: nil) }
        return Reason(kind: "similar", value: nil, count: nil)
    }

    static func suggestions(for me: String, mode: String, limit: Int, on db: any SQLDatabase) async throws -> [Suggestion] {
        // `mode` is checked against `modes` by the caller, so these literals
        // and the table name come from an allowlist, never from input.
        let modeLit = "'\(mode)'"
        let tags = mode == "work" ? ("user_skills", "skill") : ("user_interests", "interest")
        let rows = try await db.raw("""
            WITH my_friends AS (
              SELECT CASE WHEN c.requester_id = \(uuid: me) THEN c.addressee_id ELSE c.requester_id END AS uid
              FROM connections c
              WHERE c.status = 'accepted' AND c.mode = \(bind: mode)
                AND (c.requester_id = \(uuid: me) OR c.addressee_id = \(uuid: me))
            ),
            friends_of_friends AS (
              SELECT CASE WHEN c.requester_id = f.uid THEN c.addressee_id ELSE c.requester_id END AS uid,
                     COUNT(*)::int AS mutual
              FROM connections c JOIN my_friends f ON f.uid IN (c.requester_id, c.addressee_id)
              WHERE c.status = 'accepted' AND c.mode = \(bind: mode)
              GROUP BY 1
            ),
            my_vec AS (
              SELECT embedding FROM user_embedding_chunks
              WHERE user_id = \(uuid: me) AND source_type = 'user_profile' LIMIT 1
            ),
            nearest AS (
              SELECT ch.user_id AS uid FROM user_embedding_chunks ch, my_vec
              WHERE ch.source_type = 'user_profile' AND ch.user_id <> \(uuid: me)
              ORDER BY ch.embedding <=> my_vec.embedding
              LIMIT \(unsafeRaw: String(nearestProfiles))
            ),
            pool AS (SELECT uid FROM friends_of_friends UNION SELECT uid FROM nearest),
            me_row AS (
              SELECT u.company, w.province_code FROM users u
              LEFT JOIN vn_wards w ON w.id = u.ward_id WHERE u.id = \(uuid: me)
            )
            SELECT u.id::text AS id, u.username,
              \(unsafeRaw: PersonaSQL.expr("display_name", modeRef: modeLit)) AS display_name,
              \(unsafeRaw: PersonaSQL.expr("avatar_url", modeRef: modeLit)) AS avatar_url,
              u.avatar_color, u.job_title, u.company,
              \(unsafeRaw: PersonaSQL.expr("bio", modeRef: modeLit)) AS bio, u.location,
              ARRAY(SELECT t.\(unsafeRaw: tags.1) FROM \(unsafeRaw: tags.0) t WHERE t.user_id = u.id
                    ORDER BY t.\(unsafeRaw: tags.1)) AS tags,
              COALESCE(fof.mutual, 0) AS mutual_count,
              (SELECT (1 - (pc.embedding <=> my_vec.embedding))::float FROM user_embedding_chunks pc, my_vec
                WHERE pc.user_id = u.id AND pc.source_type = 'user_profile' LIMIT 1) AS similarity,
              ARRAY(SELECT t.\(unsafeRaw: tags.1) FROM \(unsafeRaw: tags.0) t
                    WHERE t.user_id = u.id AND lower(t.\(unsafeRaw: tags.1)) IN
                      (SELECT lower(m.\(unsafeRaw: tags.1)) FROM \(unsafeRaw: tags.0) m WHERE m.user_id = \(uuid: me))
                    ORDER BY t.\(unsafeRaw: tags.1)) AS shared,
              CASE WHEN u.company IS NOT NULL AND btrim(u.company) <> ''
                        AND lower(u.company) = lower((SELECT company FROM me_row)) THEN u.company END AS same_company,
              CASE WHEN w.province_code = (SELECT province_code FROM me_row) THEN w.province_name END AS same_province
            FROM pool
            JOIN users u ON u.id = pool.uid
            LEFT JOIN friends_of_friends fof ON fof.uid = u.id
            LEFT JOIN vn_wards w ON w.id = u.ward_id
            WHERE u.id <> \(uuid: me) AND u.deleted_at IS NULL AND u.show_in_suggestions
              AND \(unsafeRaw: PersonaSQL.setupClause(modeRef: modeLit))
              AND NOT EXISTS (SELECT 1 FROM user_blocks ub
                    WHERE (ub.blocker_id = \(uuid: me) AND ub.blocked_id = u.id)
                       OR (ub.blocker_id = u.id AND ub.blocked_id = \(uuid: me)))
              -- Already friends, a request either way, or one they turned
              -- down: none of those belong in "you may know".
              AND NOT EXISTS (SELECT 1 FROM connections cx WHERE cx.mode = \(bind: mode)
                    AND ((cx.requester_id = \(uuid: me) AND cx.addressee_id = u.id)
                      OR (cx.requester_id = u.id AND cx.addressee_id = \(uuid: me))))
              AND NOT EXISTS (SELECT 1 FROM suggestion_dismissals sd
                    WHERE sd.user_id = \(uuid: me) AND sd.target_id = u.id AND sd.mode = \(bind: mode))
            LIMIT \(unsafeRaw: String(poolLimit))
            """).all(decoding: Row.self)

        let scored: [(row: Row, score: Double)] = rows.map { r in
            let samePlace = (mode == "work" && r.same_company != nil) || r.same_province != nil
            let s = score(mutual: r.mutual_count, similarity: r.similarity, shared: r.shared.count, samePlace: samePlace)
            return (r, s)
        }
        let ranked = scored.sorted { a, b in a.score != b.score ? a.score > b.score : a.row.id < b.row.id }
        return ranked.prefix(limit).map { item in
            let r = item.row
            let why = reason(mode: mode, mutual: r.mutual_count, shared: r.shared,
                             sameCompany: r.same_company, sameProvince: r.same_province)
            return Suggestion(id: r.id, username: r.username, display_name: r.display_name, avatar_url: r.avatar_url,
                              avatar_color: r.avatar_color, job_title: r.job_title, company: r.company,
                              bio: r.bio, location: r.location, tags: r.tags,
                              mutual_count: r.mutual_count, match_percent: matchPercent(r.similarity), reason: why)
        }
    }

    /// Cosine similarity → the 0–100 the app shows next to a match.
    static func matchPercent(_ similarity: Double?) -> Int? {
        similarity.map { min(100, max(0, Int(($0 * 100).rounded()))) }
    }

    static func dismiss(_ target: String, by me: String, mode: String, on db: any SQLDatabase) async throws {
        try await db.raw("""
            INSERT INTO suggestion_dismissals (user_id, target_id, mode)
            VALUES (\(uuid: me), \(uuid: target), \(bind: mode))
            ON CONFLICT DO NOTHING
            """).run()
    }
}

import Vapor
import SQLKit

/// Port of the rest of `backend/src/models/userModel.js` — profile reads,
/// block graph, profile update, and account soft-delete.
extension UserStore {

    /// `escapeLike` from `backend/src/utils/sql.js`.
    static func escapeLike(_ term: String) -> String {
        var out = ""
        for ch in term {
            if ch == "\\" || ch == "%" || ch == "_" { out.append("\\") }
            out.append(ch)
        }
        return out
    }

    // MARK: userSelect fragment (shared by findAll / findById)

    /// `modeRef` nil → mode-agnostic legacy identity columns; a SQL expr (e.g.
    /// `'work'` or a bound placeholder already written by the caller) → persona.
    private static func userSelectSQL(modeRef: String?) -> String {
        let identity = modeRef.map { PersonaSQL.cols(modeRef: $0) }
            ?? "u.display_name, u.bio, u.avatar_url, u.cover_url"
        // Like connCount in findById below — post_count must be scoped to the
        // viewed mode (posts.mode), not the legacy global users.post_count
        // column, or switching modes wouldn't change the number shown.
        let postCount = modeRef.map {
            "(SELECT COUNT(*)::int FROM posts p WHERE p.author_id = u.id AND p.mode = \($0) AND p.status = 'posted') AS post_count"
        } ?? "u.post_count"
        return """
        SELECT
          u.id::text AS id, u.username,
          \(identity),
          u.avatar_color,
          CASE WHEN u.dob_visibility = 'public' THEN u.age ELSE NULL END AS age,
          u.location, u.job_title, u.company, u.default_mode,
          (u.hobby_display_name IS NOT NULL) AS hobby_setup,
          (u.work_display_name  IS NOT NULL) AS work_setup,
          u.hobby_theme, u.work_theme,
          u.follower_count, u.following_count, \(postCount),
          u.created_at,
          COALESCE(array_agg(DISTINCT ui.interest) FILTER (WHERE ui.interest IS NOT NULL), ARRAY[]::text[]) AS interests,
          COALESCE(array_agg(DISTINCT us.skill)    FILTER (WHERE us.skill    IS NOT NULL), ARRAY[]::text[]) AS skills
        FROM users u
        LEFT JOIN user_interests ui ON ui.user_id = u.id
        LEFT JOIN user_skills    us ON us.user_id = u.id
        """
    }

    // MARK: findById  (GET /api/users/:id)

    static func findById(_ id: String, mode: String?, on db: any SQLDatabase) async throws -> PublicUserObject? {
        // `mode` is validated hobby/work by the caller → safe to inline as a literal.
        let modeRef = mode.map { "'\($0)'" }
        let connCount = mode.map {
            """
            (SELECT COUNT(*)::int FROM connections c
             WHERE c.status = 'accepted' AND c.mode = '\($0)'
               AND (c.requester_id = base.id::uuid OR c.addressee_id = base.id::uuid))
            """
        } ?? "0"
        return try await db.raw("""
            SELECT base.*, \(unsafeRaw: connCount) AS connection_count
            FROM (\(unsafeRaw: userSelectSQL(modeRef: modeRef)) WHERE u.id = \(uuid: id) GROUP BY u.id) base
            """).first(decoding: PublicUserObject.self)
    }

    // MARK: findAll / countAll  (GET /api/users)

    struct ListFilters {
        var mode: String?
        var search: String?
        var viewerID: String
        var limit: Int
        var offset: Int
    }

    static func findAll(_ f: ListFilters, on db: any SQLDatabase) async throws -> [SearchUserObject] {
        let modeRef = f.mode.map { "'\($0)'" }
        let (whereSQL, likeBind) = listWhere(mode: f.mode, search: f.search, viewerRef: "\\(uuid:viewer)", alias: "u")
        _ = whereSQL; _ = likeBind
        // Build with SQLKit interpolation (auto-numbered binds).
        var q: SQLQueryString = """
            SELECT base.*, (
              SELECT COUNT(*)::int FROM (
                SELECT CASE WHEN c.requester_id = \(uuid: f.viewerID) THEN c.addressee_id ELSE c.requester_id END
                FROM connections c
                WHERE c.status = 'accepted'
            """
        if let m = f.mode { q = q + " AND c.mode = '\(unsafeRaw: m)'" }
        q = q + """
             AND (c.requester_id = \(uuid: f.viewerID) OR c.addressee_id = \(uuid: f.viewerID))
                INTERSECT
                SELECT CASE WHEN c.requester_id = base.id::uuid THEN c.addressee_id ELSE c.requester_id END
                FROM connections c
                WHERE c.status = 'accepted'
            """
        if let m = f.mode { q = q + " AND c.mode = '\(unsafeRaw: m)'" }
        q = q + """
             AND (c.requester_id = base.id::uuid OR c.addressee_id = base.id::uuid)
              ) mutual
            ) AS mutual_count
            FROM (
            \(unsafeRaw: userSelectSQL(modeRef: modeRef))
            WHERE u.deleted_at IS NULL
              AND NOT EXISTS (SELECT 1 FROM user_blocks ub
                    WHERE (ub.blocker_id = \(uuid: f.viewerID) AND ub.blocked_id = u.id)
                       OR (ub.blocker_id = u.id AND ub.blocked_id = \(uuid: f.viewerID)))
            """
        if let m = f.mode {
            q = q + " AND \(unsafeRaw: PersonaSQL.setupClause(modeRef: "'\(m)'"))"
        }
        q = q + """
             AND NOT EXISTS (SELECT 1 FROM connections c
                    WHERE c.status = 'accepted'
            """
        if let m = f.mode { q = q + " AND c.mode = '\(unsafeRaw: m)'" }
        q = q + """
                 AND ((c.requester_id = \(uuid: f.viewerID) AND c.addressee_id = u.id)
                   OR (c.requester_id = u.id AND c.addressee_id = \(uuid: f.viewerID))))
            """
        if let s = f.search, !s.isEmpty {
            let like = "%\(escapeLike(s))%"
            let nameExpr = modeRef.map { PersonaSQL.expr("display_name", modeRef: $0) } ?? "u.display_name"
            let bioExpr = modeRef.map { PersonaSQL.expr("bio", modeRef: $0) } ?? "u.bio"
            q = q + " AND (\(unsafeRaw: nameExpr) ILIKE \(bind: like) OR u.username ILIKE \(bind: like) OR u.location ILIKE \(bind: like) OR \(unsafeRaw: bioExpr) ILIKE \(bind: like)"
            if let m = f.mode {
                if m == "work" {
                    q = q + " OR u.job_title ILIKE \(bind: like) OR u.company ILIKE \(bind: like) OR EXISTS (SELECT 1 FROM user_skills us WHERE us.user_id = u.id AND us.skill ILIKE \(bind: like))"
                } else {
                    q = q + " OR EXISTS (SELECT 1 FROM user_interests ui WHERE ui.user_id = u.id AND ui.interest ILIKE \(bind: like))"
                }
            } else {
                q = q + " OR u.job_title ILIKE \(bind: like) OR u.company ILIKE \(bind: like) OR EXISTS (SELECT 1 FROM user_interests ui WHERE ui.user_id = u.id AND ui.interest ILIKE \(bind: like)) OR EXISTS (SELECT 1 FROM user_skills us WHERE us.user_id = u.id AND us.skill ILIKE \(bind: like))"
            }
            q = q + ")"
        }
        q = q + """
             GROUP BY u.id
              ORDER BY u.created_at DESC
              LIMIT \(bind: f.limit) OFFSET \(bind: f.offset)
            ) base
            ORDER BY base.created_at DESC
            """
        return try await db.raw(q).all(decoding: SearchUserObject.self)
    }

    static func countAll(mode: String?, search: String?, viewerID: String, on db: any SQLDatabase) async throws -> Int {
        var q: SQLQueryString = """
            SELECT COUNT(*)::int AS n FROM users
            WHERE deleted_at IS NULL
              AND NOT EXISTS (SELECT 1 FROM user_blocks ub
                    WHERE (ub.blocker_id = \(uuid: viewerID) AND ub.blocked_id = users.id)
                       OR (ub.blocker_id = users.id AND ub.blocked_id = \(uuid: viewerID)))
            """
        if let m = mode {
            q = q + " AND \(unsafeRaw: PersonaSQL.setupClause(modeRef: "'\(m)'", alias: "users"))"
        }
        q = q + " AND NOT EXISTS (SELECT 1 FROM connections c WHERE c.status = 'accepted'"
        if let m = mode { q = q + " AND c.mode = '\(unsafeRaw: m)'" }
        q = q + " AND ((c.requester_id = \(uuid: viewerID) AND c.addressee_id = users.id) OR (c.requester_id = users.id AND c.addressee_id = \(uuid: viewerID))))"
        if let s = search, !s.isEmpty {
            let like = "%\(escapeLike(s))%"
            let nameExpr = mode.map { PersonaSQL.expr("display_name", modeRef: "'\($0)'", alias: "users") } ?? "display_name"
            let bioExpr = mode.map { PersonaSQL.expr("bio", modeRef: "'\($0)'", alias: "users") } ?? "bio"
            q = q + " AND (\(unsafeRaw: nameExpr) ILIKE \(bind: like) OR username ILIKE \(bind: like) OR location ILIKE \(bind: like) OR \(unsafeRaw: bioExpr) ILIKE \(bind: like)"
            if let m = mode {
                if m == "work" {
                    q = q + " OR job_title ILIKE \(bind: like) OR company ILIKE \(bind: like) OR EXISTS (SELECT 1 FROM user_skills us WHERE us.user_id = users.id AND us.skill ILIKE \(bind: like))"
                } else {
                    q = q + " OR EXISTS (SELECT 1 FROM user_interests ui WHERE ui.user_id = users.id AND ui.interest ILIKE \(bind: like))"
                }
            } else {
                q = q + " OR job_title ILIKE \(bind: like) OR company ILIKE \(bind: like) OR EXISTS (SELECT 1 FROM user_interests ui WHERE ui.user_id = users.id AND ui.interest ILIKE \(bind: like)) OR EXISTS (SELECT 1 FROM user_skills us WHERE us.user_id = users.id AND us.skill ILIKE \(bind: like))"
            }
            q = q + ")"
        }
        struct N: Decodable { let n: Int }
        return try await db.raw(q).first(decoding: N.self)?.n ?? 0
    }

    // unused stub kept out of the build path
    private static func listWhere(mode: String?, search: String?, viewerRef: String, alias: String) -> (String, String) { ("", "") }

    // MARK: block graph

    static func hasBlocked(_ blocker: String, _ blocked: String, on db: any SQLDatabase) async throws -> Bool {
        try await db.raw("SELECT 1 AS x FROM user_blocks WHERE blocker_id = \(uuid: blocker) AND blocked_id = \(uuid: blocked)")
            .first() != nil
    }

    static func isBlockedEitherWay(_ a: String, _ b: String, on db: any SQLDatabase) async throws -> Bool {
        try await db.raw("""
            SELECT 1 AS x FROM user_blocks
            WHERE (blocker_id = \(uuid: a) AND blocked_id = \(uuid: b))
               OR (blocker_id = \(uuid: b) AND blocked_id = \(uuid: a))
            """).first() != nil
    }

    static func listBlocked(_ blocker: String, on db: any SQLDatabase) async throws -> [BlockedUserObject] {
        try await db.raw("""
            SELECT u.id, u.display_name, u.avatar_color, u.avatar_url, b.created_at AS blocked_at
            FROM user_blocks b JOIN users u ON u.id = b.blocked_id
            WHERE b.blocker_id = \(uuid: blocker)
            ORDER BY b.created_at DESC
            """).all(decoding: BlockedUserObject.self)
    }

    static func unblock(_ blocker: String, _ blocked: String, on db: any SQLDatabase) async throws {
        try await db.raw("DELETE FROM user_blocks WHERE blocker_id = \(uuid: blocker) AND blocked_id = \(uuid: blocked)").run()
    }

    /// block + remove any connection (accepted → decrement counts) + drop pending.
    static func block(_ blocker: String, _ blocked: String, on db: any AppDatabaseTx) async throws {
        try await db.tx { t in
            try await t.raw("INSERT INTO user_blocks (blocker_id, blocked_id) VALUES (\(uuid: blocker), \(uuid: blocked)) ON CONFLICT DO NOTHING").run()
            struct R: Decodable { let id: String }
            let accepted = try await t.raw("""
                DELETE FROM connections
                WHERE status = 'accepted'
                  AND ((requester_id = \(uuid: blocker) AND addressee_id = \(uuid: blocked))
                    OR (requester_id = \(uuid: blocked) AND addressee_id = \(uuid: blocker)))
                RETURNING id
                """).all(decoding: R.self)
            if !accepted.isEmpty {
                try await t.raw("""
                    UPDATE users
                    SET follower_count  = GREATEST(follower_count  - \(bind: accepted.count), 0),
                        following_count = GREATEST(following_count - \(bind: accepted.count), 0)
                    WHERE id IN (\(uuid: blocker), \(uuid: blocked))
                    """).run()
            }
            try await t.raw("""
                DELETE FROM connections
                WHERE (requester_id = \(uuid: blocker) AND addressee_id = \(uuid: blocked))
                   OR (requester_id = \(uuid: blocked) AND addressee_id = \(uuid: blocker))
                """).run()
        }
    }

    // MARK: updateProfile  (PATCH /api/users/me)

    static let editableColumns = ["display_name", "bio", "location", "job_title", "company",
                                  "avatar_url", "cover_url", "dob", "gender", "dob_visibility"]
    static let personaColumns: Set<String> = ["display_name", "bio", "avatar_url", "cover_url"]

    /// Partial update. `fields` maps a column name → new value (`String?`; `dob`
    /// as a `yyyy-MM-dd` string). `mode` (validated) chooses which persona the
    /// identity columns land on; when it matches `default_mode` the legacy
    /// columns are synced too. interests/skills replace fully when non-nil.
    static func updateProfile(
        userID: String, fields: [(String, String?)], interests: [String]?, skills: [String]?,
        mode: String?, on db: AppDatabase
    ) async throws -> PublicUserObject? {
        if let mode, !["hobby", "work"].contains(mode) {
            throw Abort(.internalServerError, reason: "updateProfile: invalid mode \(mode)")
        }
        var syncLegacy = false
        let sdb = db.sql()
        if let mode {
            struct M: Decodable { let default_mode: String? }
            let me = try await sdb.raw("SELECT default_mode FROM users WHERE id = \(uuid: userID)").first(decoding: M.self)
            syncLegacy = me?.default_mode == mode
        }

        try await db.tx { t in
            var sets: [SQLQueryString] = []
            var dobChanged = false
            for (col, value) in fields where editableColumns.contains(col) {
                let valExpr: SQLQueryString = col == "dob" ? "\(bind: value)::date" : "\(bind: value)"
                if let mode, personaColumns.contains(col) {
                    sets.append("\(unsafeRaw: mode)_\(unsafeRaw: col) = \(valExpr)")
                    if syncLegacy { sets.append("\(unsafeRaw: col) = \(valExpr)") }
                } else {
                    sets.append("\(unsafeRaw: col) = \(valExpr)")
                }
                if col == "dob" { dobChanged = true; _ = value }
            }
            if dobChanged, let dobVal = fields.first(where: { $0.0 == "dob" })?.1 {
                sets.append("age = EXTRACT(YEAR FROM AGE(\(bind: dobVal)::date))::int")
            } else if dobChanged {
                sets.append("age = NULL")
            }
            if !sets.isEmpty {
                var q: SQLQueryString = "UPDATE users SET "
                for (i, s) in sets.enumerated() { q = q + (i == 0 ? "" : ", ") + s }
                q = q + ", updated_at = NOW() WHERE id = \(uuid: userID)"
                try await t.raw(q).run()
            }
            if let interests {
                let clean = Array(Set(interests.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }))
                try await t.raw("DELETE FROM user_interests WHERE user_id = \(uuid: userID)").run()
                if !clean.isEmpty {
                    try await t.raw("INSERT INTO user_interests (user_id, interest) SELECT \(uuid: userID), unnest(\(bind: clean)::text[]) ON CONFLICT DO NOTHING").run()
                }
            }
            if let skills {
                let clean = Array(Set(skills.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }))
                try await t.raw("DELETE FROM user_skills WHERE user_id = \(uuid: userID)").run()
                if !clean.isEmpty {
                    try await t.raw("INSERT INTO user_skills (user_id, skill) SELECT \(uuid: userID), unnest(\(bind: clean)::text[]) ON CONFLICT DO NOTHING").run()
                }
            }
        }
        return try await findById(userID, mode: mode, on: db.sql())
    }

    // MARK: softDeleteAccount  (DELETE /api/users/me)

    /// The 6-step, ~13-write scrub from `userModel.softDeleteAccount`, one txn.
    static func softDeleteAccount(_ userID: String, on db: AppDatabase) async throws {
        try await db.tx { t in
            try await t.raw("""
                WITH gone AS (
                  DELETE FROM connections
                  WHERE status = 'accepted' AND (requester_id = \(uuid: userID) OR addressee_id = \(uuid: userID))
                  RETURNING CASE WHEN requester_id = \(uuid: userID) THEN addressee_id ELSE requester_id END AS other_id
                )
                UPDATE users SET
                  follower_count  = GREATEST(follower_count  - g.cnt, 0),
                  following_count = GREATEST(following_count - g.cnt, 0)
                FROM (SELECT other_id, COUNT(*)::int AS cnt FROM gone GROUP BY other_id) g
                WHERE users.id = g.other_id
                """).run()
            try await t.raw("DELETE FROM connections WHERE requester_id = \(uuid: userID) OR addressee_id = \(uuid: userID)").run()
            try await t.raw("""
                WITH sole_admin AS (
                  SELECT cm.community_id FROM community_members cm
                  WHERE cm.user_id = \(uuid: userID) AND cm.role = 'admin'
                    AND NOT EXISTS (SELECT 1 FROM community_members o
                      WHERE o.community_id = cm.community_id AND o.user_id <> \(uuid: userID) AND o.role = 'admin')
                ),
                successor AS (
                  SELECT DISTINCT ON (m.community_id) m.community_id, m.user_id
                  FROM community_members m JOIN sole_admin s ON s.community_id = m.community_id
                  WHERE m.user_id <> \(uuid: userID)
                  ORDER BY m.community_id, CASE m.role WHEN 'moderator' THEN 0 ELSE 1 END, m.joined_at ASC
                )
                UPDATE community_members cm SET role = 'admin'
                FROM successor su
                WHERE cm.community_id = su.community_id AND cm.user_id = su.user_id
                """).run()
            try await t.raw("""
                WITH gone AS (DELETE FROM community_members WHERE user_id = \(uuid: userID) RETURNING community_id)
                UPDATE communities SET member_count = GREATEST(member_count - 1, 0)
                WHERE id IN (SELECT community_id FROM gone)
                """).run()
            try await t.raw("DELETE FROM user_embedding_chunks WHERE user_id = \(uuid: userID)").run()
            try await t.raw("DELETE FROM user_interests  WHERE user_id = \(uuid: userID)").run()
            try await t.raw("DELETE FROM user_skills     WHERE user_id = \(uuid: userID)").run()
            try await t.raw("DELETE FROM stories         WHERE author_id = \(uuid: userID)").run()
            try await t.raw("DELETE FROM user_blocks     WHERE blocker_id = \(uuid: userID) OR blocked_id = \(uuid: userID)").run()
            try await t.raw("DELETE FROM password_resets WHERE user_id = \(uuid: userID)").run()
            try await t.raw("DELETE FROM user_notifications WHERE user_id = \(uuid: userID)").run()
            try await t.raw("""
                UPDATE users SET
                  username      = 'deleted_' || SUBSTRING(REPLACE(id::text, '-', ''), 1, 12),
                  display_name  = 'Deleted User',
                  password_hash = NULL, email = NULL, google_id = NULL, phone = NULL,
                  avatar_url = NULL, bio = NULL,
                  hobby_display_name = NULL, hobby_bio = NULL, hobby_avatar_url = NULL, hobby_cover_url = NULL,
                  work_display_name = NULL, work_bio = NULL, work_avatar_url = NULL, work_cover_url = NULL,
                  job_title = NULL, company = NULL, location = NULL, ward_id = NULL, dob = NULL,
                  avatar_color = '#9E9E9E', deleted_at = NOW(), updated_at = NOW()
                WHERE id = \(uuid: userID)
                """).run()
        }
    }
}

/// Tiny protocol so store methods can take "something that runs a transaction".
protocol AppDatabaseTx {
    func tx(_ work: @Sendable @escaping (any SQLDatabase) async throws -> Void) async throws
}
extension AppDatabase: AppDatabaseTx {
    func tx(_ work: @Sendable @escaping (any SQLDatabase) async throws -> Void) async throws {
        _ = try await withTransaction { db -> Int in try await work(db); return 0 }
    }
}

import Vapor
import SQLKit

/// Profile reads, block graph, profile update, and account soft-delete.
extension UserStore {

    /// Escapes `%`, `_` and `\` so a search term is matched literally by LIKE.
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
            ?? "u.display_name, u.bio, u.bio_format, u.avatar_url, u.cover_url"
        // Like connCount in findById below, post_count must be scoped to the
        // viewed mode (posts.mode), not the legacy global users.post_count
        // column, or switching modes wouldn't change the number shown. Must
        // also mirror PostStore.feedWhere's author-scoped branch exactly:
        // community posts are excluded from a personal profile's feed/count
        // (they belong on the community's own page. See the comment on
        // feedWhere's `p.community_id IS NULL` clause), so without this the
        // stats row overcounts by however many community posts the user has.
        // Marketplace listings are left out for the same reason: they live on
        // the Marketplace tab, and the profile's list (`includeListings` off)
        // doesn't show them, so counting them put "9 posts" over a list of 5.
        // Public and friends posts count, for every viewer; only-me posts are
        // private notes and never do.
        let postCount = modeRef.map {
            "(SELECT COUNT(*)::int FROM posts p WHERE p.author_id = u.id AND p.mode = \($0) AND p.status = 'posted' AND p.community_id IS NULL AND p.post_type NOT IN ('listing', 'legit') AND p.privacy IN ('public', 'friends')) AS post_count"
        } ?? "u.post_count"
        // Mode-scoped and friends-excluded (FollowStore); the legacy
        // users.follower_count/following_count columns only mirrored friends.
        // Hobby-only details (migration 062): empty in a Work view.
        let hobbyDetails = modeRef.map {
            "CASE WHEN \($0) = 'work' THEN ARRAY[]::text[] ELSE u.languages END AS languages, CASE WHEN \($0) = 'work' THEN NULL ELSE u.relationship_status END AS relationship_status"
        } ?? "u.languages, u.relationship_status"
        // HR is a Work identity: a Hobby (or mode-less) view never shows it.
        let hrCompany = modeRef.map {
            "CASE WHEN \($0) = 'work' THEN (SELECT r.company_name FROM recruiters r WHERE r.user_id = u.id) END AS hr_company"
        } ?? "NULL::text AS hr_company"
        let followCounts = modeRef.map { FollowStore.countColumns(userRef: "u.id", modeRef: $0) }
            ?? "u.follower_count, u.following_count"
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
          \(hobbyDetails),
          \(followCounts), \(postCount),
          u.app_role = 'admin' AS is_official,
          \(hrCompany),
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
        // This persona's "See my other profile" switch (migration 060).
        let link = """
            (SELECT CASE WHEN \(modeRef ?? "x.default_mode") = 'work' THEN x.work_links_hobby ELSE x.hobby_links_work END
             FROM users x WHERE x.id = base.id::uuid)
            """
        let locked = """
            (SELECT CASE WHEN \(modeRef ?? "x.default_mode") = 'work' THEN x.work_locked ELSE x.hobby_locked END
             FROM users x WHERE x.id = base.id::uuid)
            """
        return try await db.raw("""
            SELECT base.*, \(unsafeRaw: connCount) AS connection_count, \(unsafeRaw: link) AS links_other_mode,
              \(unsafeRaw: locked) AS is_locked
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
            """
        if let s = f.search, !s.isEmpty {
            // Ranked by relevance, not recency: the score has to ride along
            // as a column (`search_score`) so the outer ORDER BY keeps the
            // order the LIMIT was taken in.
            q = q + rankedSearchSQL(f, query: s)
                + " ORDER BY r.search_score DESC, r.created_at DESC LIMIT \(bind: f.limit) OFFSET \(bind: f.offset)"
                + ") base ORDER BY base.search_score DESC, base.created_at DESC"
        } else {
            // Nothing typed: the people most like the viewer first, by profile
            // vector. The score only orders the list and is never sent, so no
            // match % shows here. No vector on either side falls back to newest.
            q = q + "SELECT s.* FROM (SELECT c.*, " + profileSimilaritySQL(viewer: f.viewerID)
                + " AS similarity_score FROM (" + eligibleUsersSQL(f) + ") c) s"
                + " ORDER BY s.similarity_score DESC NULLS LAST, s.created_at DESC LIMIT \(bind: f.limit) OFFSET \(bind: f.offset)"
                + ") base ORDER BY base.similarity_score DESC NULLS LAST, base.created_at DESC"
        }
        return try await db.raw(q).all(decoding: SearchUserObject.self)
    }

    /// Users the viewer may see in a list: not deleted, not blocked either
    /// way, set up in this mode, not already connected. One row per user
    /// with `userSelectSQL`'s columns (alias-free; callers wrap it).
    private static func eligibleUsersSQL(_ f: ListFilters) -> SQLQueryString {
        let modeRef = f.mode.map { "'\($0)'" }
        var q: SQLQueryString = """
            \(unsafeRaw: userSelectSQL(modeRef: modeRef))
            WHERE u.deleted_at IS NULL AND u.id <> \(uuid: f.viewerID)
              AND NOT EXISTS (SELECT 1 FROM user_blocks ub
                    WHERE (ub.blocker_id = \(uuid: f.viewerID) AND ub.blocked_id = u.id)
                       OR (ub.blocker_id = u.id AND ub.blocked_id = \(uuid: f.viewerID)))
            """
        if let m = f.mode { q = q + " AND " + AccountBans.visible(userRef: "u.id", mode: m, viewer: f.viewerID) }
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
             GROUP BY u.id
            """
        return q
    }

    /// Cosine similarity between row `c`'s profile vector and the viewer's,
    /// NULL when either has none yet.
    private static func profileSimilaritySQL(viewer: String) -> SQLQueryString {
        """
        (SELECT (1 - (pc.embedding <=> mv.embedding))::float
           FROM user_embedding_chunks pc, user_embedding_chunks mv
          WHERE pc.user_id = c.id::uuid AND pc.source_type = 'user_profile' AND pc.chunk_index = 0
            AND mv.user_id = \(uuid: viewer) AND mv.source_type = 'user_profile' AND mv.chunk_index = 0
          LIMIT 1)
        """
    }

    /// Eligible users that match `query`, each with a `search_score`, aliased
    /// `r` and not yet ordered or limited. Shared by `findAll` and `countAll`
    /// so the total always counts exactly what the list can page through.
    private static func rankedSearchSQL(_ f: ListFilters, query: String) -> SQLQueryString {
        let words = SearchTokenizer.words(query)
        return "SELECT r.* FROM (SELECT c.*, "
            + peopleRelevance(query: query, words: words)
            + " AS search_score FROM (" + eligibleUsersSQL(f) + ") c) r WHERE "
            + peopleMatch(words: words, alias: "r")
    }

    /// `unaccent(lower(coalesce(col, '')))`, both sides of every keyword
    /// comparison are folded this way, so "meo" finds "Mèo".
    private static func folded(_ col: String) -> String { "unaccent(lower(coalesce(\(col), '')))" }

    /// A word typed without accents matches any accents ("thanh" finds Thành);
    /// one typed with accents is the more specific ask and matches them exactly
    /// ("thành" skips Thanh). Both sides are NFC so composed/decomposed tone
    /// marks compare equal.
    static func isPlain(_ word: String) -> Bool { word.unicodeScalars.allSatisfy(\.isASCII) }

    private static func displayName(_ alias: String, plain: Bool) -> String {
        plain ? folded("\(alias).display_name") : "normalize(lower(coalesce(\(alias).display_name, '')), NFC)"
    }

    /// Whether `word` starts any word of the display name. Leading space +
    /// non-alphanumerics → spaces, so "% word" also matches the first word.
    private static func startsNameWord(_ alias: String, _ word: String) -> SQLQueryString {
        let name = "(' ' || regexp_replace(\(displayName(alias, plain: isPlain(word))), '[^[:alnum:]]+', ' ', 'g'))"
        return "\(unsafeRaw: name) LIKE '% ' || \(bind: word.precomposedStringWithCanonicalMapping) || '%'"
    }

    /// Typed (non-AI) search is a word search over who someone *is*: every
    /// word must start a word of the display name or appear in the @username.
    /// Bio, job, interests and location are left to AI search, a substring hit
    /// there (accent-folded "hoàn thành" contains "thanh") surfaced strangers.
    /// Words come from `SearchTokenizer` (letters/digits only) and are bound.
    static func peopleMatch(words: [String], alias: String) -> SQLQueryString {
        guard !words.isEmpty else { return "FALSE" }
        var all: SQLQueryString = "(TRUE"
        for w in words {
            all = all + " AND (" + startsNameWord(alias, w)
                + " OR lower(\(unsafeRaw: alias).username) LIKE '%' || \(bind: w) || '%')"
        }
        return all + ")"
    }

    /// Ranks rows that pass `peopleMatch`: an exact name/username match first,
    /// then words that start the name or username over ones only inside it.
    static func peopleRelevance(query: String, words: [String]) -> SQLQueryString {
        let username = "lower(c.username)"
        let q = query.lowercased().trimmingCharacters(in: .whitespaces).precomposedStringWithCanonicalMapping
        let name = displayName("c", plain: isPlain(q))

        var score: SQLQueryString = "(CASE WHEN \(unsafeRaw: name) = \(bind: q) OR \(unsafeRaw: username) = \(bind: q) THEN 100 ELSE 0 END"
        for w in words {
            score = score
                + " + CASE WHEN " + startsNameWord("c", w) + " THEN 40 ELSE 0 END"
                + " + CASE WHEN \(unsafeRaw: username) LIKE \(bind: w) || '%' THEN 40"
                + " WHEN \(unsafeRaw: username) LIKE '%' || \(bind: w) || '%' THEN 20 ELSE 0 END"
        }
        return score + ")"
    }

    static func countAll(mode: String?, search: String?, viewerID: String, on db: any SQLDatabase) async throws -> Int {
        struct N: Decodable { let n: Int }
        if let s = search, !s.isEmpty {
            // Count the same ranked set `findAll` pages through.
            let f = ListFilters(mode: mode, search: s, viewerID: viewerID, limit: 0, offset: 0)
            let q: SQLQueryString = "SELECT COUNT(*)::int AS n FROM (" + rankedSearchSQL(f, query: s) + ") counted"
            return try await db.raw(q).first(decoding: N.self)?.n ?? 0
        }
        var q: SQLQueryString = """
            SELECT COUNT(*)::int AS n FROM users
            WHERE deleted_at IS NULL AND id <> \(uuid: viewerID)
              AND NOT EXISTS (SELECT 1 FROM user_blocks ub
                    WHERE (ub.blocker_id = \(uuid: viewerID) AND ub.blocked_id = users.id)
                       OR (ub.blocker_id = users.id AND ub.blocked_id = \(uuid: viewerID)))
            """
        if let m = mode { q = q + " AND " + AccountBans.visible(userRef: "users.id", mode: m, viewer: viewerID) }
        if let m = mode {
            q = q + " AND \(unsafeRaw: PersonaSQL.setupClause(modeRef: "'\(m)'", alias: "users"))"
        }
        q = q + " AND NOT EXISTS (SELECT 1 FROM connections c WHERE c.status = 'accepted'"
        if let m = mode { q = q + " AND c.mode = '\(unsafeRaw: m)'" }
        q = q + " AND ((c.requester_id = \(uuid: viewerID) AND c.addressee_id = users.id) OR (c.requester_id = users.id AND c.addressee_id = \(uuid: viewerID))))"
        return try await db.raw(q).first(decoding: N.self)?.n ?? 0
    }

    // MARK: block graph

    /// Whether a live (not deleted) account has this id.
    static func isActive(_ id: String, on db: any SQLDatabase) async throws -> Bool {
        struct R: Decodable { let one: Int }
        return try await db.raw("SELECT 1 AS one FROM users WHERE id = \(uuid: id) AND deleted_at IS NULL")
            .first(decoding: R.self) != nil
    }

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
            try await FollowStore.removeBetween(blocker, blocked, on: t)
        }
    }

    // MARK: updateProfile  (PATCH /api/users/me)

    static let editableColumns = ["display_name", "bio", "bio_format", "location", "job_title", "company",
                                  "avatar_url", "cover_url", "dob", "gender", "dob_visibility"]
    static let personaColumns: Set<String> = ["display_name", "bio", "bio_format", "avatar_url", "cover_url"]

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
            var fields = fields
            if let newDob = fields.first(where: { $0.0 == "dob" })?.1 as String?? {
                // Locked so two saves at once can't both spend the last change.
                struct D: Decodable { let dob: String?; let dob_changes: Int }
                let current = try await t.raw("""
                    SELECT to_char(dob, 'YYYY-MM-DD') AS dob, dob_changes FROM users WHERE id = \(uuid: userID) FOR UPDATE
                    """).first(decoding: D.self)
                if BirthdayRules.isChange(from: current?.dob, to: newDob) {
                    guard BirthdayRules.changesLeft(used: current?.dob_changes ?? 0) > 0 else {
                        throw InlineError(.forbidden, BirthdayRules.limitReason)
                    }
                    sets.append("dob_changes = dob_changes + 1")
                } else {
                    fields.removeAll { $0.0 == "dob" }
                }
            }
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
                // Kept skills keep their row, and so their endorsements.
                try await EndorsementStore.replaceSkills(of: userID, with: skills, on: t)
            }
        }
        return try await findById(userID, mode: mode, on: db.sql())
    }

    // MARK: softDeleteAccount  (DELETE /api/users/me)

    /// The 6-step, ~13-write scrub from `userModel.softDeleteAccount`, one txn.
    static func softDeleteAccount(_ userID: String, on db: AppDatabase, logger: Logger) async throws {
        // Listed first: the rows that name the files are gone after the scrub.
        let files = try await AccountDeletionStore.uploadPaths(of: userID, on: db.sql())
        try await db.tx { t in
            try await scrubAccountData(userID, on: t)
            // The username is kept: it's the account's ID, so it stays taken
            // for good (usernameTaken matches deleted rows too).
            try await t.raw("""
                UPDATE users SET
                  display_name  = 'Deleted User', email_verified_at = NULL,
                  password_hash = NULL, email = NULL, google_id = NULL, phone = NULL,
                  avatar_url = NULL, bio = NULL,
                  hobby_display_name = NULL, hobby_bio = NULL, hobby_avatar_url = NULL, hobby_cover_url = NULL,
                  work_display_name = NULL, work_bio = NULL, work_avatar_url = NULL, work_cover_url = NULL,
                  job_title = NULL, company = NULL, location = NULL, ward_id = NULL, dob = NULL,
                  cover_url = NULL, age = NULL, gender = 'other', dob_visibility = 'private',
                  languages = '{}', relationship_status = NULL, two_factor_enabled = FALSE,
                  avatar_color = '#9E9E9E', deleted_at = NOW(), updated_at = NOW()
                WHERE id = \(uuid: userID)
                """).run()
        }
        AccountDeletionStore.deleteUploads(files, logger: logger)
    }

    /// Everything an account owns except its `users` row. Shared by account
    /// deletion and by `OfficialAccountCommand`, which keeps the row and its login.
    static func scrubAccountData(_ userID: String, on t: any SQLDatabase) async throws {
        // Their posts, comments, likes and stories go (both modes).
        try await AccountDeletionStore.removeActivity(of: userID, mode: nil, on: t)
        try await AccountDeletionStore.removePersonalData(of: userID, on: t)
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
        // `community_members_one_admin` is checked row by row, so the leaver
        // gives up the role before a successor takes it; their row is deleted
        // just below anyway.
        try await t.raw("""
            UPDATE community_members SET role = 'member'
            WHERE user_id = \(uuid: userID) AND role = 'admin'
            """).run()
        try await t.raw("""
            WITH sole_admin AS (
              SELECT cm.community_id FROM community_members cm
              WHERE cm.user_id = \(uuid: userID)
                AND NOT EXISTS (SELECT 1 FROM community_members o
                  WHERE o.community_id = cm.community_id AND o.role = 'admin')
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
        try await t.raw("DELETE FROM account_codes   WHERE user_id = \(uuid: userID)").run()
        try await t.raw("DELETE FROM user_notifications WHERE user_id = \(uuid: userID)").run()
    }
}

extension UserStore {
    /// A new @username, at most once per `UsernameRules.cooldownMonths`. The
    /// old one goes into `username_history`, where nobody else can take it.
    static func changeUsername(userID: String, to raw: String?, now: Date = Date(), on db: AppDatabase) async throws {
        let username = UsernameRules.normalized(raw)
        guard UsernameRules.isValidFormat(username) else { throw InlineError(.badRequest, UsernameRules.formatReason) }
        do {
            try await db.tx { t in
                // Locked so two requests at once can't both use the same change.
                struct Row: Decodable { let username: String; let username_changed_at: Date? }
                guard let current = try await t.raw("""
                    SELECT username, username_changed_at FROM users
                    WHERE id = \(uuid: userID) AND deleted_at IS NULL FOR UPDATE
                    """).first(decoding: Row.self) else {
                    throw InlineError(.notFound, "User not found")
                }
                guard current.username != username else { throw InlineError(.badRequest, UsernameRules.sameReason) }
                if !UsernameRules.canChange(lastChangedAt: current.username_changed_at, now: now),
                   let next = UsernameRules.nextChange(after: current.username_changed_at) {
                    throw InlineError(.forbidden, UsernameRules.cooldownReason(until: next))
                }
                if try await usernameTaken(username, excluding: userID, on: t) {
                    throw InlineError(.conflict, UsernameRules.takenReason)
                }
                try await t.raw("""
                    INSERT INTO username_history (username, user_id) VALUES (\(bind: current.username), \(uuid: userID))
                    ON CONFLICT (username) DO UPDATE SET user_id = EXCLUDED.user_id, released_at = NOW()
                    """).run()
                // Taking back a name you released: it's yours again, not history.
                try await t.raw("DELETE FROM username_history WHERE username = \(bind: username) AND user_id = \(uuid: userID)").run()
                try await t.raw("""
                    UPDATE users SET username = \(bind: username), username_changed_at = NOW(), updated_at = NOW()
                    WHERE id = \(uuid: userID)
                    """).run()
            }
        } catch where PGError.isUniqueViolation(error) {
            // Someone signed up with it between the check and the update.
            throw InlineError(.conflict, UsernameRules.takenReason)
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

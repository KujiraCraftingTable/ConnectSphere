import Vapor
import SQLKit

/// Deleting one persona (Hobby or Work) while the account and the other
/// persona stay, migration 061. The whole account is
/// `UserStore.softDeleteAccount`; both remove the person's posts, comments,
/// likes and stories through `removeActivity`.
enum AccountDeletionStore {
    /// `mode` must already be "hobby" or "work", it's inlined into column names.
    static func deletePersona(_ user: String, mode: String, on db: AppDatabase) async throws {
        precondition(["hobby", "work"].contains(mode), "mode is allowlisted by the caller")
        let other = mode == "work" ? "hobby" : "work"
        try await db.tx { t in
            try await removeActivity(of: user, mode: mode, on: t)

            // That mode's connections: everyone's counts drop by one per
            // connection, mine by all of them (as softDeleteAccount does).
            struct N: Decodable { let n: Int }
            let mine = try await t.raw("""
                SELECT COUNT(*)::int AS n FROM connections
                WHERE mode = \(bind: mode) AND status = 'accepted' AND (requester_id = \(uuid: user) OR addressee_id = \(uuid: user))
                """).first(decoding: N.self)?.n ?? 0
            try await t.raw("""
                WITH gone AS (
                  DELETE FROM connections
                  WHERE mode = \(bind: mode) AND status = 'accepted' AND (requester_id = \(uuid: user) OR addressee_id = \(uuid: user))
                  RETURNING CASE WHEN requester_id = \(uuid: user) THEN addressee_id ELSE requester_id END AS other_id
                )
                UPDATE users SET
                  follower_count  = GREATEST(follower_count  - g.cnt, 0),
                  following_count = GREATEST(following_count - g.cnt, 0)
                FROM (SELECT other_id, COUNT(*)::int AS cnt FROM gone GROUP BY other_id) g
                WHERE users.id = g.other_id
                """).run()
            try await t.raw("""
                UPDATE users SET follower_count = GREATEST(follower_count - \(bind: mine), 0),
                                 following_count = GREATEST(following_count - \(bind: mine), 0)
                WHERE id = \(uuid: user)
                """).run()
            try await t.raw("DELETE FROM connections WHERE mode = \(bind: mode) AND (requester_id = \(uuid: user) OR addressee_id = \(uuid: user))").run()
            try await t.raw("DELETE FROM follows WHERE mode = \(bind: mode) AND (follower_id = \(uuid: user) OR followee_id = \(uuid: user))").run()
            try await t.raw("DELETE FROM muted_words WHERE user_id = \(uuid: user) AND mode = \(bind: mode)").run()
            try await t.raw("DELETE FROM suggestion_dismissals WHERE mode = \(bind: mode) AND (user_id = \(uuid: user) OR target_id = \(uuid: user))").run()

            // Chats: what they sent stays and reads "Deleted User" (PersonaSQL,
            // *_deleted_at). They leave that mode's groups; a 1:1 chat keeps
            // them as its other side, or it would vanish from the other
            // person's inbox, but is cleared and archived on their end.
            try await t.raw("""
                DELETE FROM conversation_participants cp USING conversations c
                WHERE cp.conversation_id = c.id AND c.mode = \(bind: mode) AND c.is_group AND cp.user_id = \(uuid: user)
                """).run()
            try await t.raw("""
                UPDATE conversation_participants cp SET cleared_at = NOW(), archived_at = NOW()
                FROM conversations c
                WHERE cp.conversation_id = c.id AND c.mode = \(bind: mode) AND NOT c.is_group AND cp.user_id = \(uuid: user)
                """).run()
            try await t.raw("DELETE FROM chat_spaces WHERE owner_id = \(uuid: user) AND mode = \(bind: mode)").run()
            try await t.raw("""
                DELETE FROM user_notifications
                WHERE (user_id = \(uuid: user) OR actor_id = \(uuid: user)) AND payload->>'mode' = \(bind: mode)
                """).run()

            if mode == "work" {
                try await removeWorkLife(of: user, on: t)
            } else {
                try await t.raw("DELETE FROM user_interests WHERE user_id = \(uuid: user)").run()
            }

            try await t.raw("""
                UPDATE users SET
                  \(unsafeRaw: mode)_display_name = NULL, \(unsafeRaw: mode)_bio = NULL,
                  \(unsafeRaw: mode)_avatar_url = NULL, \(unsafeRaw: mode)_cover_url = NULL,
                  \(unsafeRaw: mode)_theme = DEFAULT, \(unsafeRaw: mode)_deleted_at = NOW(),
                  default_mode = \(bind: other), updated_at = NOW()
                WHERE id = \(uuid: user)
                """).run()
        }
    }

    /// Their posts (with everything hanging off them), their comments and
    /// likes on other posts, keeping those posts' counts right, and their
    /// stories. `mode` nil = both modes (account deletion).
    static func removeActivity(of user: String, mode: String?, on t: any SQLDatabase) async throws {
        // Leading space: it's appended to queries that end mid-line.
        let inMode: SQLQueryString = mode.map { " AND p.mode = \(bind: $0)" } ?? ""
        struct Ids: Decodable { let ids: [UUID]? }
        try await t.raw("DELETE FROM posts p WHERE p.author_id = \(uuid: user) " + inMode).run()

        let commented = try await t.raw("""
            SELECT array_agg(DISTINCT c.post_id) AS ids FROM comments c JOIN posts p ON p.id = c.post_id
            WHERE c.author_id = \(uuid: user)
            """ + inMode).first(decoding: Ids.self)?.ids ?? []
        try await t.raw("""
            DELETE FROM comments c USING posts p
            WHERE p.id = c.post_id AND c.author_id = \(uuid: user)
            """ + inMode).run()
        if !commented.isEmpty {
            // Replies under their comments went too (cascade), so recount.
            try await t.raw("""
                UPDATE posts SET comment_count = (SELECT COUNT(*)::int FROM comments x WHERE x.post_id = posts.id)
                WHERE id = ANY(\(bind: commented))
                """).run()
        }

        let liked = try await t.raw("""
            SELECT array_agg(DISTINCT l.post_id) AS ids FROM post_likes l JOIN posts p ON p.id = l.post_id
            WHERE l.user_id = \(uuid: user)
            """ + inMode).first(decoding: Ids.self)?.ids ?? []
        // post_reactions is a view over post_likes + comments, both cleaned here.
        try await t.raw("DELETE FROM post_likes l USING posts p WHERE p.id = l.post_id AND l.user_id = \(uuid: user) " + inMode).run()
        if !liked.isEmpty {
            try await t.raw("""
                UPDATE posts SET like_count = (SELECT COUNT(*)::int FROM post_likes x WHERE x.post_id = posts.id)
                WHERE id = ANY(\(bind: liked))
                """).run()
        }

        let storyMode: SQLQueryString = mode.map { " AND mode = \(bind: $0)" } ?? ""
        try await t.raw("DELETE FROM stories WHERE author_id = \(uuid: user) " + storyMode).run()
    }

    /// The Work-only side: experience, skills (their endorsements cascade),
    /// endorsements given, applications, saved jobs, company follows and
    /// admin roles. A company page they alone manage is deleted; one with
    /// other admins gets a new owner if they were it.
    static func removeWorkLife(of user: String, on t: any SQLDatabase) async throws {
        try await t.raw("DELETE FROM work_experiences WHERE user_id = \(uuid: user)").run()
        try await t.raw("DELETE FROM user_skills WHERE user_id = \(uuid: user)").run()
        try await t.raw("DELETE FROM skill_endorsements WHERE endorser_id = \(uuid: user)").run()
        try await t.raw("DELETE FROM job_applications WHERE applicant_id = \(uuid: user)").run()
        try await t.raw("DELETE FROM job_interests WHERE user_id = \(uuid: user)").run()
        try await t.raw("""
            WITH gone AS (DELETE FROM company_followers WHERE user_id = \(uuid: user) RETURNING company_id)
            UPDATE companies SET follower_count = GREATEST(follower_count - 1, 0)
            WHERE id IN (SELECT company_id FROM gone)
            """).run()
        try await t.raw("""
            DELETE FROM companies c
            WHERE EXISTS (SELECT 1 FROM company_admins a WHERE a.company_id = c.id AND a.user_id = \(uuid: user))
              AND NOT EXISTS (SELECT 1 FROM company_admins o WHERE o.company_id = c.id AND o.user_id <> \(uuid: user))
            """).run()
        try await t.raw("""
            WITH successor AS (
              SELECT DISTINCT ON (o.company_id) o.company_id, o.user_id
              FROM company_admins me JOIN company_admins o ON o.company_id = me.company_id AND o.user_id <> me.user_id
              WHERE me.user_id = \(uuid: user) AND me.role = 'owner'
              ORDER BY o.company_id, o.added_at
            )
            UPDATE company_admins a SET role = 'owner'
            FROM successor s WHERE a.company_id = s.company_id AND a.user_id = s.user_id
            """).run()
        try await t.raw("DELETE FROM company_admins WHERE user_id = \(uuid: user)").run()
        try await t.raw("UPDATE users SET job_title = NULL, company = NULL WHERE id = \(uuid: user)").run()
    }

    // MARK: whole account

    /// Rows that belong to one person and mean nothing without them. Table and
    /// column names are literals from this list, never user input. Messages,
    /// conversation memberships and moderation reports are left on purpose:
    /// other people's chats and the safety record depend on them.
    private static let personalRows: [(table: String, column: String)] = [
        ("educations", "user_id"), ("highlights", "user_id"),
        ("follows", "follower_id"), ("follows", "followee_id"),
        ("muted_words", "user_id"),
        ("search_results", "shown_user_id"), ("search_sessions", "user_id"),
        ("post_impressions", "user_id"),
        ("post_feedback", "user_id"), ("post_feedback", "author_id"),
        ("saved_posts", "user_id"), ("hidden_posts", "user_id"), ("story_views", "viewer_id"),
        ("suggestion_dismissals", "user_id"), ("suggestion_dismissals", "target_id"),
        ("interest_suggestions", "user_id"), ("recommendation_interests", "user_id"),
        ("chat_space_members", "user_id"), ("chat_spaces", "owner_id"),
        ("comment_likes", "user_id"), ("poll_votes", "user_id"), ("event_rsvps", "user_id"),
        ("community_join_requests", "user_id"),
        ("community_bans", "user_id"),
        ("message_reactions", "user_id"), ("message_meeting_rsvps", "user_id"),
        ("chat_poll_votes", "user_id"), ("conversation_nicknames", "setter_id"),
        ("conversation_nicknames", "target_id"), ("conversation_block_acks", "user_id"),
        ("message_receipts", "user_id"), ("listing_auto_replies", "buyer_id"),
        // The Dating space is archived (legacy/dating), but its tables stay and may still hold rows.
        ("dating_likes", "from_user"), ("dating_likes", "to_user"),
        ("dating_matches", "user_a"), ("dating_matches", "user_b"),
        ("dating_profiles", "user_id"),   // its photos go with it (ON DELETE CASCADE)
    ]

    /// Everything account deletion removes beyond `removeActivity`: the Work side
    /// (CV applications, experience, endorsements) and the rest of `personalRows`.
    static func removePersonalData(of user: String, on t: any SQLDatabase) async throws {
        try await removeWorkLife(of: user, on: t)
        for (table, column) in personalRows {
            try await t.raw("DELETE FROM \(unsafeRaw: table) WHERE \(unsafeRaw: column) = \(uuid: user)").run()
        }
    }

    // MARK: uploaded files

    /// The `/uploads/…` files only this person's content uses: their post and
    /// comment photos, stories, avatars and covers, highlights, Dating photos
    /// and CVs. Chat media stays, the messages stay for the other people.
    static func uploadPaths(of user: String, on db: any SQLDatabase) async throws -> [String] {
        struct P: Decodable { let path: String? }
        let rows = try await db.raw("""
            SELECT x AS path FROM (
              SELECT unnest(image_urls) AS x FROM posts WHERE author_id = \(uuid: user)
              UNION ALL SELECT image_url FROM comments WHERE author_id = \(uuid: user)
              UNION ALL SELECT image_url FROM stories WHERE author_id = \(uuid: user)
              UNION ALL SELECT v FROM users u, LATERAL (VALUES (u.avatar_url), (u.cover_url), (u.hobby_avatar_url),
                (u.hobby_cover_url), (u.work_avatar_url), (u.work_cover_url)) AS t(v) WHERE u.id = \(uuid: user)
              UNION ALL SELECT cover_url FROM highlights WHERE user_id = \(uuid: user)
              UNION ALL SELECT i.image_url FROM highlight_items i JOIN highlights h ON h.id = i.highlight_id WHERE h.user_id = \(uuid: user)
              UNION ALL SELECT url FROM dating_photos WHERE user_id = \(uuid: user)
              UNION ALL SELECT cv_url FROM job_applications WHERE applicant_id = \(uuid: user)
            ) f WHERE x IS NOT NULL
            """).all(decoding: P.self)
        return Array(Set(rows.compactMap(\.path)))
    }

    /// Removes the files (and a photo's `_t.jpg` thumbnail). A failure is logged
    /// and skipped: the account is already gone and a leftover file is harmless.
    static func deleteUploads(_ paths: [String], logger: Logger) {
        let fm = FileManager.default
        for path in paths {
            // Only our own uploads folder, never an outside link or a path with "..".
            guard path.hasPrefix("/uploads/"), !path.contains("..") else { continue }
            let file = UploadsController.uploadDir + path.dropFirst("/uploads".count)
            var targets = [file]
            if let dot = file.lastIndex(of: ".") { targets.append(String(file[..<dot]) + "_t.jpg") }
            for target in targets where fm.fileExists(atPath: target) {
                do { try fm.removeItem(atPath: target) }
                catch { logger.warning("account deletion: could not remove an upload: \(error)") }
            }
        }
    }
}

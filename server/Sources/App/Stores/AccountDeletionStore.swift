import Vapor
import SQLKit

/// Deleting one persona (Hobby or Work) while the account and the other
/// persona stay — migration 061. The whole account is
/// `UserStore.softDeleteAccount`; both remove the person's posts, comments,
/// likes and stories through `removeActivity`.
enum AccountDeletionStore {
    /// `mode` must already be "hobby" or "work" — it's inlined into column names.
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
            // them as its other side — or it would vanish from the other
            // person's inbox — but is cleared and archived on their end.
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
    /// likes on other posts — keeping those posts' counts right — and their
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
    private static func removeWorkLife(of user: String, on t: any SQLDatabase) async throws {
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
}

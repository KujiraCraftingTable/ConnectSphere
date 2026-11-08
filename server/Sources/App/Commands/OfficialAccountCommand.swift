import Vapor
import SQLKit

/// `swift run App official-account status | tidy | claim --user <name> [--commit]`
///
/// Turns an existing account into the official @connectsphere account, the
/// app's only admin (migration 104). Everything the account had is erased:
/// posts, comments, likes, stories, connections, follows, the messages it sent,
/// its chat memberships, profile and photos. The `users` row stays with its id,
/// email, password and 2FA, so the owner signs in with the same email and
/// password. Communities it ran pass to their next member (as on account
/// deletion); one left with no members is deleted.
///
/// Without `--commit` it only prints what would go, because none of it can be
/// undone. ConsoleKit eats `--yes`, hence `--commit` (as in `seed-demo`).
struct OfficialAccountCommand: AsyncCommand {
    static let username = "connectsphere"
    static let displayName = "ConnectSphere"

    struct Signature: CommandSignature {
        @Argument(name: "action", help: "status, tidy or claim") var action: String
        @Option(name: "user", help: "Username to turn into the official account, with or without the @.") var user: String?
        @Flag(name: "commit", help: "Actually erase and convert. Without it, only a dry run.") var commit: Bool
    }

    var help: String { "Shows the official account, or turns an existing account into it (erasing its data)." }

    func run(using context: CommandContext, signature: Signature) async throws {
        let db = context.application.db.sql()
        switch signature.action {
        case "status":
            struct Row: Decodable { let username: String; let email: String? }
            if let row = try await db.raw("""
                SELECT username, email FROM users WHERE app_role = 'admin' AND deleted_at IS NULL
                """).first(decoding: Row.self) {
                context.console.info("Official account: @\(row.username) (\(row.email ?? "no email"))")
            } else {
                context.console.info("No official account yet.")
            }
        case "claim":
            try await claim(context, signature, db)
        case "tidy":
            struct Row: Decodable { let id: String; let username: String }
            guard let row = try await db.raw("""
                SELECT id::text AS id, username FROM users WHERE app_role = 'admin' AND deleted_at IS NULL
                """).first(decoding: Row.self) else {
                context.console.error("No official account yet. Run claim first.")
                return
            }
            try await context.application.db.tx { t in try await Self.tidy(row.id, on: t) }
            context.console.info("@\(row.username): least information kept (name and pictures only), both profiles named \(Self.displayName).")
        default:
            context.console.error("Unknown action \(signature.action), use status, tidy or claim.")
        }
    }

    private func claim(_ context: CommandContext, _ signature: Signature, _ db: any SQLDatabase) async throws {
        guard let name = signature.user?.trimmingCharacters(in: CharacterSet(charactersIn: "@ ")).lowercased(),
              !name.isEmpty else {
            context.console.error("Pass --user <username>.")
            return
        }
        struct Target: Decodable { let id: String }
        guard let target = try await db.raw("""
            SELECT id::text AS id FROM users WHERE username = \(bind: name) AND deleted_at IS NULL
            """).first(decoding: Target.self) else {
            context.console.error("No active account @\(name).")
            return
        }
        struct Other: Decodable { let username: String }
        if let other = try await db.raw("""
            SELECT username FROM users
            WHERE app_role = 'admin' AND deleted_at IS NULL AND id <> \(uuid: target.id)
            """).first(decoding: Other.self) {
            context.console.error("@\(other.username) is already the admin. Run `moderator revoke --user \(other.username)` first.")
            return
        }
        // usernameTaken matches deleted rows too, so a deleted @connectsphere still blocks it.
        if name != Self.username, try await db.raw("""
            SELECT 1 AS one FROM users WHERE username = \(bind: Self.username)
            """).first() != nil {
            context.console.error("@\(Self.username) is already taken by another account.")
            return
        }

        let counts = try await Self.counts(of: target.id, on: db)
        context.console.info("@\(name) → @\(Self.username), the only admin. This erases:")
        for (label, n) in counts { context.console.info("  \(n) \(label)") }
        context.console.info("Kept: user id, email, password, 2FA. Other devices are signed out.")
        guard signature.commit else {
            context.console.warning("Dry run. Nothing changed. Add --commit to do it; it cannot be undone.")
            return
        }

        let app = context.application
        let files = try await AccountDeletionStore.uploadPaths(of: target.id, on: db)
        try await app.db.tx { t in
            try await UserStore.scrubAccountData(target.id, on: t)
            // Beyond account deletion, which keeps these so other people's chats
            // stay whole: the official account starts with no history at all.
            try await t.raw("DELETE FROM messages WHERE sender_id = \(uuid: target.id)").run()
            try await t.raw("DELETE FROM conversation_participants WHERE user_id = \(uuid: target.id)").run()
            try await t.raw("DELETE FROM user_notifications WHERE actor_id = \(uuid: target.id)").run()
            try await t.raw("""
                DELETE FROM communities c WHERE c.created_by = \(uuid: target.id)
                  AND NOT EXISTS (SELECT 1 FROM community_members m WHERE m.community_id = c.id)
                """).run()
            try await t.raw("""
                UPDATE users SET
                  username = \(bind: Self.username), app_role = 'admin',
                  display_name = \(bind: Self.displayName),
                  hobby_display_name = CASE WHEN hobby_display_name IS NULL THEN NULL ELSE \(bind: Self.displayName) END,
                  work_display_name  = CASE WHEN work_display_name  IS NULL THEN NULL ELSE \(bind: Self.displayName) END,
                  bio = NULL, hobby_bio = NULL, work_bio = NULL,
                  avatar_url = NULL, hobby_avatar_url = NULL, work_avatar_url = NULL,
                  cover_url = NULL, hobby_cover_url = NULL, work_cover_url = NULL,
                  job_title = NULL, company = NULL, phone = NULL,
                  gender = 'other', dob_visibility = 'private', languages = '{}', relationship_status = NULL,
                  follower_count = 0, following_count = 0, post_count = 0,
                  sessions_valid_after = NOW(), updated_at = NOW()
                WHERE id = \(uuid: target.id)
                """).run()
            try await Self.tidy(target.id, on: t)
        }
        AccountDeletionStore.deleteUploads(files, logger: app.logger)
        context.console.info("Done. Sign in as @\(Self.username) with the same email and password.")
    }

    /// The official account's least information, safe to run again: both
    /// profiles named ConnectSphere (it posts in Hobby and Work), and no
    /// location, birthday, about, work, education, interests or skills.
    static func tidy(_ id: String, on t: any SQLDatabase) async throws {
        try await t.raw("""
            UPDATE users SET
              display_name = \(bind: displayName),
              hobby_display_name = \(bind: displayName), work_display_name = \(bind: displayName),
              bio = NULL, hobby_bio = NULL, work_bio = NULL,
              location = NULL, ward_id = NULL, dob = NULL, age = NULL, dob_visibility = 'private',
              job_title = NULL, company = NULL, phone = NULL, gender = 'other',
              languages = '{}', relationship_status = NULL, updated_at = NOW()
            WHERE id = \(uuid: id)
            """).run()
        for table in ["user_interests", "user_skills", "educations", "work_experiences"] {
            try await t.raw("DELETE FROM \(unsafeRaw: table) WHERE user_id = \(uuid: id)").run()
        }
        // No connections either way; followers stay, and it follows no one.
        // Accepted connections are counted on both sides, as on account deletion.
        try await t.raw("""
            WITH gone AS (
              DELETE FROM connections
              WHERE status = 'accepted' AND (requester_id = \(uuid: id) OR addressee_id = \(uuid: id))
              RETURNING CASE WHEN requester_id = \(uuid: id) THEN addressee_id ELSE requester_id END AS other_id
            )
            UPDATE users SET
              follower_count  = GREATEST(follower_count  - g.cnt, 0),
              following_count = GREATEST(following_count - g.cnt, 0)
            FROM (SELECT other_id, COUNT(*)::int AS cnt FROM gone GROUP BY other_id) g
            WHERE users.id = g.other_id
            """).run()
        try await t.raw("DELETE FROM connections WHERE requester_id = \(uuid: id) OR addressee_id = \(uuid: id)").run()
        try await t.raw("UPDATE users SET follower_count = 0, following_count = 0 WHERE id = \(uuid: id)").run()
        try await t.raw("DELETE FROM follows WHERE follower_id = \(uuid: id)").run()
    }

    /// What `claim` erases, for the dry run.
    static func counts(of id: String, on db: any SQLDatabase) async throws -> [(String, Int)] {
        struct N: Decodable { let posts: Int; let comments: Int; let connections: Int; let follows: Int
                              let messages: Int; let chats: Int; let communities: Int; let stories: Int }
        guard let n = try await db.raw("""
            SELECT
              (SELECT COUNT(*) FROM posts WHERE author_id = \(uuid: id))::int AS posts,
              (SELECT COUNT(*) FROM comments WHERE author_id = \(uuid: id))::int AS comments,
              (SELECT COUNT(*) FROM connections WHERE requester_id = \(uuid: id) OR addressee_id = \(uuid: id))::int AS connections,
              (SELECT COUNT(*) FROM follows WHERE follower_id = \(uuid: id) OR followee_id = \(uuid: id))::int AS follows,
              (SELECT COUNT(*) FROM messages WHERE sender_id = \(uuid: id))::int AS messages,
              (SELECT COUNT(*) FROM conversation_participants WHERE user_id = \(uuid: id))::int AS chats,
              (SELECT COUNT(*) FROM communities WHERE created_by = \(uuid: id))::int AS communities,
              (SELECT COUNT(*) FROM stories WHERE author_id = \(uuid: id))::int AS stories
            """).first(decoding: N.self) else { return [] }
        return [("posts", n.posts), ("comments", n.comments), ("connections", n.connections),
                ("follows", n.follows), ("messages sent", n.messages), ("chat memberships", n.chats),
                ("communities created (handed to their next member, or deleted if empty)", n.communities),
                ("stories", n.stories)]
    }
}

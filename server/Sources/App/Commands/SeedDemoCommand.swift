import Vapor
import SQLKit

/// `swift run App seed-demo <action>`. Manages the demo population.
///
/// `wipe` removes the old seed people (`password_hash = 'SEED_DATA'`), the
/// contract-test accounts and the hand-made QA accounts, then recounts every
/// denormalized counter. Without `--commit` it runs the whole thing inside a
/// transaction that is rolled back and only reports; with `--commit` it backs the
/// database up with `pg_dump` first and commits.
struct SeedDemoCommand: AsyncCommand {
    struct Signature: CommandSignature {
        @Argument(name: "action", help: "wipe | seed | embed | communities") var action: String
        @Flag(name: "commit", help: "Back up, then actually delete (default is a rolled-back dry run).") var commit: Bool
    }

    var help: String {
        "Demo data: `wipe` removes seed / contract-test / QA accounts; `seed` writes the 40 demo people from Seeds/; `embed` builds their vectors and AI tags; `communities` replaces all communities and listings with Seeds/demo-communities.json."
    }

    func run(using context: CommandContext, signature: Signature) async throws {
        switch signature.action {
        case "wipe":
            try await wipe(context, commit: signature.commit)
        case "seed":
            try await seed(context)
        case "embed":
            try await embed(context)
        case "communities":
            try await seedCommunities(context, commit: signature.commit)
        default:
            context.console.error("Unknown action \(signature.action). Available: wipe, seed, embed, communities")
        }
    }

    // MARK: - Who goes

    /// The real accounts. The wipe refuses to run if its selection touches any
    /// of them, or anyone who signs in with Google.
    static let keepUsernames = [
        "kujira1307", "kujira_sigma", "takataiyo", "user_94947730", "user_4yvvq4og", "user_41780231",
        "sigmameow", "bobom8426", "naytestmowo", "kujira_manual_1", "meowsingapore", "hehengauwa",
        "first_username", "coldstart_test1",
    ]

    /// Made by an early API test run; such accounts can still sit in an old database.
    static let contractUsernamePattern = "^p(1|2|3|4|4b|4c|5|u)_[0-9]+_"

    /// Accounts the XCUITest suite makes (`TestHooksController`). Each run
    /// deletes its own; this catches what a crashed run left behind.
    static let uiTestUsernamePattern = "^qa_ui_[a-z0-9]{8}_[0-9]+$"

    /// Hand-made QA accounts from earlier feature checks, confirmed one by one
    /// on 2026-11-03.
    static let qaUsernames = [
        "qa1787220411_alpha", "qa1787220411_beta", "qa_test_bugfix1", "qcfix1787223107",
        "qcuser1_1787224187", "qcuser2_1787224187", "qctesta1787543130", "qctestb1787543130",
        "agetest1setup", "agetest2_1787246592", "agetest3_1787246637", "agetest_search",
        "agetest1_1787247104", "agetest2_1787247104",
        "mtest1_1787252071", "mtest2_1787252071", "mtest1_1787252094", "mtest2_1787252094",
        "testusera_1787541779", "testuserb_1787541779", "testusera_1787541844", "testuserb_1787541844",
        "gtest_alice", "gtest_bob", "gtest_carol", "gtest_dave", "gtest_erin",
        "ra1787580783", "rb1787580783", "rc1787580783",
        "phase1_owner", "phase1_member", "phase1_outsider", "phase1_mod", "phase1_member2",
        "hashtagtestuser", "hashtagtester2608", "bugtest_phase2",
        "p5analyze1", "p5an2", "p5search1", "p5s2", "p5s3", "p5s4", "p5qr",
        "dbg_1788926061n", "nx_1788939953996a", "nx_1788939953996b", "cutover1", "p8smoke1",
        "conntest_5043", "devtest_32704", "test",
        "delete_fix_verify_002", "delete_fix_verify_003", "delete_fix_verify_004",
        "delete_fix_verify_005", "delete_fix_verify_006",
        "jobpost_verify_001", "jobpost_verify_002", "jobpost_verify_003", "jobpost_verify_004",
    ]

    // MARK: - Wipe

    private struct Doomed: Decodable { let id: UUID; let username: String; let google: Bool; let grp: String }
    private struct N: Decodable { let n: Int }
    struct DryRun: Error { let lines: [String] }

    /// Tables whose row counts are reported before and after (literals only).
    private static let reportedTables = [
        "users", "posts", "comments", "post_likes", "connections", "follows", "conversations", "messages",
        "communities", "companies", "stories", "user_embedding_chunks", "search_sessions",
    ]

    private func wipe(_ context: CommandContext, commit: Bool) async throws {
        let app = context.application
        let doomed = try await app.db.sql().raw("""
            SELECT id, username, google_id IS NOT NULL AS google,
                   CASE WHEN password_hash = 'SEED_DATA' THEN 'seed'
                        WHEN username ~ \(bind: Self.contractUsernamePattern) THEN 'contract'
                        ELSE 'qa' END AS grp
            FROM users
            WHERE password_hash = 'SEED_DATA'
               OR username ~ \(bind: Self.contractUsernamePattern)
               OR username ~ \(bind: Self.uiTestUsernamePattern)
               OR username = ANY(\(bind: Self.qaUsernames))
            """).all(decoding: Doomed.self)

        let kept = doomed.filter { Self.keepUsernames.contains($0.username) || $0.google }
        guard kept.isEmpty else {
            context.console.error("Refusing to wipe: the selection includes kept or Google accounts: "
                + kept.map(\.username).joined(separator: ", "))
            return
        }
        guard !doomed.isEmpty else { context.console.info("Nothing to wipe."); return }
        let groups = Dictionary(grouping: doomed, by: \.grp).mapValues(\.count)
        context.console.info("Selected \(doomed.count) accounts, seed \(groups["seed"] ?? 0), "
            + "contract \(groups["contract"] ?? 0), QA \(groups["qa"] ?? 0).")

        if commit { try backUp(context) }

        let ids = doomed.map(\.id)
        do {
            let lines = try await app.db.withTransaction { t -> [String] in
                let before = try await Self.tableCounts(on: t)
                var lines = try await Self.deleteAccounts(ids, on: t)
                lines += try await Self.recountCounters(on: t)
                let after = try await Self.tableCounts(on: t)
                lines += Self.reportedTables.map { "\($0): \(before[$0] ?? 0) → \(after[$0] ?? 0)" }
                if !commit { throw DryRun(lines: lines) }
                return lines
            }
            lines.forEach { context.console.info($0) }
            context.console.info("Wipe committed.")
        } catch let dry as DryRun {
            dry.lines.forEach { context.console.info($0) }
            context.console.warning("Dry run, rolled back. Re-run with --commit to back up and delete.")
        }
    }

    /// Returns one report line per step that changed something.
    static func deleteAccounts(_ ids: [UUID], on t: any SQLDatabase) async throws -> [String] {
        let steps: [(String, SQLQueryString)] = [
            // `pinned_by` is NOT NULL with ON DELETE SET NULL, so the user
            // delete would fail on these.
            ("message pins by them", "DELETE FROM message_pins WHERE pinned_by = ANY(\(bind: ids))"),
            // NO ACTION foreign keys: a reviewer / resolver being deleted blocks the delete.
            ("join requests they reviewed (reviewer cleared)",
             "UPDATE community_join_requests SET reviewed_by = NULL WHERE reviewed_by = ANY(\(bind: ids))"),
            ("reports they resolved (resolver cleared)",
             "UPDATE community_reports SET resolved_by = NULL WHERE resolved_by = ANY(\(bind: ids))"),
            // Their communities cascade away, but `posts.community_id` is SET
            // NULL, anyone else's posts there would turn into profile posts.
            ("posts in communities they created",
             "DELETE FROM posts WHERE community_id IN (SELECT id FROM communities WHERE created_by = ANY(\(bind: ids)))"),
            // Participants cascade, conversations don't: a chat whose other
            // side is all leaving would stay behind, one-sided.
            ("conversations with no one else left", """
             DELETE FROM conversations c
             WHERE EXISTS (SELECT 1 FROM conversation_participants p WHERE p.conversation_id = c.id AND p.user_id = ANY(\(bind: ids)))
               AND (SELECT COUNT(*) FROM conversation_participants p
                    WHERE p.conversation_id = c.id AND NOT (p.user_id = ANY(\(bind: ids)))) <= 1
             """),
            ("users", "DELETE FROM users WHERE id = ANY(\(bind: ids))"),
            ("empty conversations",
             "DELETE FROM conversations c WHERE NOT EXISTS (SELECT 1 FROM conversation_participants p WHERE p.conversation_id = c.id)"),
            ("company pages with no admin",
             "DELETE FROM companies c WHERE NOT EXISTS (SELECT 1 FROM company_admins a WHERE a.company_id = c.id)"),
        ]
        var lines: [String] = []
        for (label, sql) in steps {
            let n = try await t.raw("WITH done AS (" + sql + " RETURNING 1) SELECT COUNT(*)::int AS n FROM done")
                .first(decoding: N.self)?.n ?? 0
            if n > 0 { lines.append("deleted/updated \(n): \(label)") }
        }
        return lines
    }

    /// Every denormalized counter set to what its rows say. Including back to
    /// zero where no rows remain;
    /// each source yields `(id, n)` for every row of the target table.
    static func recountCounters(on t: any SQLDatabase) async throws -> [String] {
        let connections = """
            SELECT u.id, COUNT(c.requester_id)::int AS n FROM users u
            LEFT JOIN connections c ON c.status = 'accepted' AND u.id IN (c.requester_id, c.addressee_id) GROUP BY u.id
            """
        let counters: [(table: String, column: String, source: String)] = [
            ("users", "post_count", """
             SELECT u.id, COUNT(p.id)::int AS n FROM users u
             LEFT JOIN posts p ON p.author_id = u.id AND p.status = 'posted' AND p.community_id IS NULL GROUP BY u.id
             """),
            // Connections are mutual, so both counts are the accepted connections.
            ("users", "follower_count", connections),
            ("users", "following_count", connections),
            ("posts", "like_count",
             "SELECT p.id, COUNT(l.user_id)::int AS n FROM posts p LEFT JOIN post_likes l ON l.post_id = p.id GROUP BY p.id"),
            ("posts", "comment_count", """
             SELECT p.id, COUNT(c.id)::int AS n FROM posts p
             LEFT JOIN comments c ON c.post_id = p.id AND c.status = 'posted' GROUP BY p.id
             """),
            ("posts", "share_count", """
             SELECT p.id, COUNT(s.id)::int AS n FROM posts p
             LEFT JOIN posts s ON s.shared_post_id = p.id AND s.status = 'posted' GROUP BY p.id
             """),
            ("comments", "like_count",
             "SELECT c.id, COUNT(l.user_id)::int AS n FROM comments c LEFT JOIN comment_likes l ON l.comment_id = c.id GROUP BY c.id"),
            ("communities", "member_count",
             "SELECT c.id, COUNT(m.user_id)::int AS n FROM communities c LEFT JOIN community_members m ON m.community_id = c.id GROUP BY c.id"),
            ("communities", "post_count", """
             SELECT c.id, COUNT(p.id)::int AS n FROM communities c
             LEFT JOIN posts p ON p.community_id = c.id AND p.status = 'posted' GROUP BY c.id
             """),
            ("companies", "follower_count",
             "SELECT c.id, COUNT(f.user_id)::int AS n FROM companies c LEFT JOIN company_followers f ON f.company_id = c.id GROUP BY c.id"),
            ("poll_options", "vote_count",
             "SELECT o.id, COUNT(v.user_id)::int AS n FROM poll_options o LEFT JOIN poll_votes v ON v.poll_option_id = o.id GROUP BY o.id"),
            ("chat_poll_options", "vote_count",
             "SELECT o.id, COUNT(v.user_id)::int AS n FROM chat_poll_options o LEFT JOIN chat_poll_votes v ON v.option_id = o.id GROUP BY o.id"),
            ("community_events", "rsvp_count", """
             SELECT e.id, COUNT(r.user_id)::int AS n FROM community_events e
             LEFT JOIN event_rsvps r ON r.event_id = e.id AND r.status = 'going' GROUP BY e.id
             """),
            ("job_posts", "interested_count",
             "SELECT j.id, COUNT(i.user_id)::int AS n FROM job_posts j LEFT JOIN job_interests i ON i.job_id = j.id GROUP BY j.id"),
        ]
        var lines: [String] = []
        for c in counters {
            // Table, column and source are the literals above, never input.
            let n = try await t.raw("""
                WITH src AS (\(unsafeRaw: c.source)),
                fixed AS (
                  UPDATE \(unsafeRaw: c.table) t SET \(unsafeRaw: c.column) = src.n FROM src
                  WHERE t.id = src.id AND t.\(unsafeRaw: c.column) <> src.n RETURNING 1
                )
                SELECT COUNT(*)::int AS n FROM fixed
                """).first(decoding: N.self)?.n ?? 0
            if n > 0 { lines.append("recounted \(n): \(c.table).\(c.column)") }
        }
        return lines
    }

    private static func tableCounts(on t: any SQLDatabase) async throws -> [String: Int] {
        var counts: [String: Int] = [:]
        for table in reportedTables {
            counts[table] = try await t.raw("SELECT COUNT(*)::int AS n FROM \(unsafeRaw: table)")
                .first(decoding: N.self)?.n ?? 0
        }
        return counts
    }

    // MARK: - Backup

    /// `pg_dump` of the Postgres container into `backend/backups/`. Never
    /// overwrites an earlier backup, so a second run can't replace the
    /// pre-wipe copy with a post-wipe one.
    func backUp(_ context: CommandContext) throws {
        let app = context.application
        let dir = URL(fileURLWithPath: app.directory.workingDirectory + "../backend/backups").standardizedFileURL
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let file = dir.appendingPathComponent("pre-reseed-\(formatter.string(from: Date())).sql")
        guard FileManager.default.createFile(atPath: file.path, contents: nil) else {
            throw Abort(.internalServerError, reason: "Could not create \(file.path)")
        }
        let out = try FileHandle(forWritingTo: file)
        defer { try? out.close() }

        let container = Environment.get("DB_CONTAINER") ?? "connectsphere_db"
        let dump = Process()
        dump.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        dump.arguments = ["docker", "exec", container, "pg_dump", "-U", app.appEnv.db.user, "-d", app.appEnv.db.database]
        dump.standardOutput = out
        try dump.run()
        dump.waitUntilExit()

        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
        guard dump.terminationStatus == 0, size > 0 else {
            throw Abort(.internalServerError, reason: "pg_dump failed (exit \(dump.terminationStatus)); nothing was deleted")
        }
        context.console.info("Backup: \(file.path) (\(size / 1024) KB)")
    }
}

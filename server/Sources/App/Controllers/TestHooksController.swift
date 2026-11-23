import Vapor
import SQLKit
import NIOConcurrencyHelpers

/// `/api/test/*`: what the XCUITest suite needs from the server and can't do
/// through the app. Throwaway `qa_ui_<run>_<n>` accounts, the plaintext of an
/// emailed code, and deleting a run's accounts afterwards.
///
/// Only mounted when `UITEST_HOOKS=1` (never in production, see `AppEnv`);
/// every request must come from loopback and carry `X-UITest-Token`.
struct TestHooksController {
    static func register(routes: any RoutesBuilder, app: Application) {
        guard app.appEnv.uitest.hooksEnabled else { return }
        let test = routes.grouped("test").grouped(Guard(token: app.appEnv.uitest.token))
        test.post("users", use: createUsers)
        test.get("last-code", use: lastCode)
        test.delete("runs", ":runID", use: deleteRun)
        test.post("runs", ":runID", "embed", use: embedRun)
        test.post("recruiters", use: makeRecruiter)
        test.post("communities", use: createCommunity)
        test.post("deals", use: createDeal)
        app.logger.warning("UITEST_HOOKS=1: /api/test routes are mounted (loopback + token only)")
    }

    // MARK: - Guard

    struct Guard: AsyncMiddleware {
        let token: String

        func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
            guard Self.isLoopback(request.remoteAddress?.ipAddress),
                  Self.tokensMatch(request.headers.first(name: "X-UITest-Token"), token)
            else { throw Abort(.notFound) }
            return try await next.respond(to: request)
        }

        static func isLoopback(_ ip: String?) -> Bool {
            guard let ip else { return false }
            return ip == "127.0.0.1" || ip == "::1" || ip == "::ffff:127.0.0.1"
        }

        /// Constant time, so the token can't be guessed a byte at a time.
        static func tokensMatch(_ given: String?, _ expected: String) -> Bool {
            guard let given, !expected.isEmpty else { return false }
            let a = Array(given.utf8), b = Array(expected.utf8)
            guard a.count == b.count else { return false }
            return zip(a, b).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
        }
    }

    // MARK: - Validation

    /// A run id is 8 lowercase letters/digits, so usernames stay inside
    /// `SeedDemoCommand.uiTestUsernamePattern` and nothing else can match.
    static func isValidRunID(_ s: String) -> Bool {
        s.count == 8 && s.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) }
    }

    static let kinds = ["basic", "two_factor", "verified_email"]
    static let maxCount = 5

    static func username(run: String, n: Int) -> String { "qa_ui_\(run)_\(n)" }
    static func email(run: String, n: Int) -> String { "qa_ui_\(run)_\(n)@example.test" }

    // MARK: - POST /test/users

    struct CreateBody: Content {
        var run_id: String?; var kind: String?; var count: Int?
        /// Optional search fixture: the same bio and interests on every account made.
        var bio: String?; var interests: [String]?
    }
    static let maxInterests = 10
    static let maxInterestLength = 40
    struct Created: Content { var id: String; var username: String; var password: String; var email: String?; var token: String }

    /// Set-up accounts, `created_at` three days back so the new-account limits
    /// (`UserRateLimiter`) don't slow the suite. `two_factor` ones have a
    /// verified email and two-factor sign-in on; `verified_email` ones the email only.
    @Sendable static func createUsers(_ req: Request) async throws -> [Created] {
        let b = try req.content.decode(CreateBody.self)
        let run = b.run_id ?? ""
        let kind = b.kind ?? "basic"
        let count = b.count ?? 1
        guard isValidRunID(run) else { throw Abort(.badRequest, reason: "run_id must be 8 lowercase letters or digits") }
        guard kinds.contains(kind) else { throw Abort(.badRequest, reason: "kind must be one of \(kinds.joined(separator: ", "))") }
        guard (1...maxCount).contains(count) else { throw Abort(.badRequest, reason: "count must be 1-\(maxCount)") }
        let interests = b.interests?.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard (interests?.count ?? 0) <= maxInterests, interests?.allSatisfy({ $0.count <= maxInterestLength }) ?? true else {
            throw Abort(.badRequest, reason: "at most \(maxInterests) interests of \(maxInterestLength) characters")
        }

        let db = req.db.sql()
        struct W: Decodable { let id: String }
        guard let ward = try await db.raw("SELECT id::text AS id FROM vn_wards ORDER BY id LIMIT 1").first(decoding: W.self) else {
            throw Abort(.internalServerError, reason: "no wards loaded")
        }
        struct N: Decodable { let n: Int }
        let taken = try await db.raw("SELECT COUNT(*)::int AS n FROM users WHERE username ~ \(bind: "^qa_ui_\(run)_[0-9]+$")")
            .first(decoding: N.self)?.n ?? 0

        var created: [Created] = []
        for i in 1...count {
            let n = taken + i
            let username = username(run: run, n: n)
            let email = kind == "basic" ? nil : email(run: run, n: n)
            let password = "Qa-" + [UInt8].random(count: 12).map { String(format: "%02x", $0) }.joined()
            let hash = try await req.password.async.hash(password)
            let fields = try await AuthController.ProfileFields.validate(.init(
                username: username, display_name: "QA \(run) \(n)", dob: "2000-01-01", dob_visibility: "private",
                bio: b.bio, ward_id: ward.id, default_mode: "hobby", job_title: nil, company: nil, gender: "other",
                interests: interests, skills: nil, accepted_policy_version: nil), on: db)
            let id = try await req.db.withTransaction { t -> String in
                struct NewRow: Decodable { let id: String }
                guard let row = try await t.raw("""
                    INSERT INTO users (username, email, email_verified_at, password_hash, display_name, is_setup,
                                       two_factor_enabled, created_at)
                    VALUES (\(bind: username), \(bind: email), CASE WHEN \(bind: email) IS NULL THEN NULL ELSE NOW() END,
                            \(bind: hash), \(bind: username), FALSE, \(bind: kind == "two_factor"), NOW() - INTERVAL '3 days')
                    RETURNING id::text AS id
                    """).first(decoding: NewRow.self)
                else { throw Abort(.internalServerError) }
                try await AuthController.applyProfile(row.id, username: username, fields, on: t)
                // Work set up too, so a mode switch lands on the Work feed, not the persona form.
                try await t.raw("UPDATE users SET work_display_name = display_name WHERE id = \(uuid: row.id)").run()
                try await ConsentStore.record(row.id, on: t)
                return row.id
            }
            created.append(Created(id: id, username: username, password: password, email: email,
                                   token: AuthController.signToken(id, req)))
        }
        return created
    }

    // MARK: - GET /test/last-code?email=

    struct Code: Content { var code: String }

    @Sendable static func lastCode(_ req: Request) async throws -> Code {
        let email = ((try? req.query.get(String.self, at: "email")) ?? "").lowercased()
        guard email.hasPrefix("qa_ui_"), let code = TestCodeSink.shared.last(for: email) else {
            throw Abort(.notFound, reason: "no code sent to that address")
        }
        return Code(code: code)
    }

    // MARK: - POST /test/runs/:runID/embed

    struct Embedded: Content { var built: Int }

    /// Builds the run's profile chunks now. The :3001 server runs without jobs,
    /// so nothing else would embed them before an AI search test looks.
    @Sendable static func embedRun(_ req: Request) async throws -> Embedded {
        let run = req.parameters.get("runID") ?? ""
        guard isValidRunID(run) else { throw Abort(.badRequest, reason: "run_id must be 8 lowercase letters or digits") }
        let db = req.db.sql()
        struct U: Decodable { let id: String }
        let users = try await db.raw("SELECT id::text AS id FROM users WHERE username ~ \(bind: "^qa_ui_\(run)_[0-9]+$")")
            .all(decoding: U.self)
        var built = 0
        for u in users where try await ChunkService.buildProfileChunk(u.id, cfg: req.application.ollama, on: db, logger: req.logger) {
            built += 1
        }
        return Embedded(built: built)
    }

    // MARK: - Fixtures owned by a run account (they go with it on delete)

    struct OwnerBody: Content { var user_id: String?; var name: String? }

    /// The id, if `userID` belongs to a UI-test run; fixtures attach to nothing else.
    private static func runUser(_ userID: String?, on db: any SQLDatabase) async throws -> String {
        guard let userID, UUID(uuidString: userID) != nil else { throw Abort(.badRequest, reason: "user_id must be a UUID") }
        struct U: Decodable { let id: String }
        guard let row = try await db.raw("""
            SELECT id::text AS id FROM users
            WHERE id = \(uuid: userID) AND username ~ \(bind: SeedDemoCommand.uiTestUsernamePattern)
            """).first(decoding: U.self)
        else { throw Abort(.notFound, reason: "not a UI-test account") }
        return row.id
    }

    /// A verified recruiter with no trial posts left, so its jobs go live
    /// without admin review (`PostService`).
    @Sendable static func makeRecruiter(_ req: Request) async throws -> HTTPStatus {
        let b = try req.content.decode(OwnerBody.self)
        let db = req.db.sql()
        let id = try await runUser(b.user_id, on: db)
        // tax_code is UNIQUE; 10 random digits won't collide in practice.
        let taxCode = (0..<10).map { _ in String(Int.random(in: 0...9)) }.joined()
        try await db.raw("""
            INSERT INTO recruiters (user_id, company_name, tax_code, trial_left)
            VALUES (\(uuid: id), 'QA Test Company', \(bind: taxCode), 0)
            ON CONFLICT (user_id) DO NOTHING
            """).run()
        return .created
    }

    struct CommunityCreated: Content { var id: String }

    /// A public Hobby community with the account as its admin, no cover.
    @Sendable static func createCommunity(_ req: Request) async throws -> CommunityCreated {
        let b = try req.content.decode(OwnerBody.self)
        let name = (b.name ?? "").trimmingCharacters(in: .whitespaces)
        guard (3...100).contains(name.count) else { throw Abort(.badRequest, reason: "name must be 3-100 characters") }
        let id = try await runUser(b.user_id, on: req.db.sql())
        return try await req.db.withTransaction { t in
            struct R: Decodable { let id: String }
            guard let row = try await t.raw("""
                INSERT INTO communities (name, description, description_format, type, privacy, created_by)
                VALUES (\(bind: name), 'A UI-test community.', 'markdown', 'fandom', 'public', \(uuid: id))
                RETURNING id::text AS id
                """).first(decoding: R.self)
            else { throw Abort(.internalServerError) }
            _ = try await CommunityStore.joinCommunity(row.id, id, role: "admin", on: t)
            try await CommunityStore.incrementMemberCount(row.id, 1, on: t)
            return CommunityCreated(id: row.id)
        }
    }

    struct DealBody: Content {
        var seller_id: String?; var buyer_id: String?
        var title: String?; var price: Int64?; var quantity: Int?
    }
    struct DealCreated: Content { var id: String }

    /// A confirmed Hobby sale between two run accounts, as `deal_records`
    /// stores it when a seller confirms a deposit, without the listing and
    /// chat that lead there.
    @Sendable static func createDeal(_ req: Request) async throws -> DealCreated {
        let b = try req.content.decode(DealBody.self)
        let title = (b.title ?? "").trimmingCharacters(in: .whitespaces)
        guard (1...100).contains(title.count) else { throw Abort(.badRequest, reason: "title must be 1-100 characters") }
        let quantity = b.quantity ?? 1
        guard (1...20).contains(quantity) else { throw Abort(.badRequest, reason: "quantity must be 1-20") }
        if let price = b.price, price < 0 { throw Abort(.badRequest, reason: "price must not be negative") }
        let db = req.db.sql()
        let seller = try await runUser(b.seller_id, on: db)
        let buyer = try await runUser(b.buyer_id, on: db)
        guard seller != buyer else { throw Abort(.badRequest, reason: "seller and buyer must differ") }
        struct R: Decodable { let id: String }
        guard let row = try await db.raw("""
            INSERT INTO deal_records (seller_id, buyer_id, seller_username, buyer_username, mode,
                                      item_title, item_price, quantity)
            SELECT s.id, b.id, s.username, b.username, 'hobby', \(bind: title), \(bind: b.price), \(bind: quantity)
            FROM users s, users b WHERE s.id = \(uuid: seller) AND b.id = \(uuid: buyer)
            RETURNING id::text AS id
            """).first(decoding: R.self)
        else { throw Abort(.internalServerError) }
        return DealCreated(id: row.id)
    }

    // MARK: - DELETE /test/runs/:runID

    struct Deleted: Content { var users: Int; var steps: [String] }

    /// Removes every account of the run with the same steps as
    /// `seed-demo wipe`, then recounts the counters they touched.
    @Sendable static func deleteRun(_ req: Request) async throws -> Deleted {
        let run = req.parameters.get("runID") ?? ""
        guard isValidRunID(run) else { throw Abort(.badRequest, reason: "run_id must be 8 lowercase letters or digits") }
        struct U: Decodable { let id: UUID }
        let ids = try await req.db.sql().raw("""
            SELECT id FROM users WHERE username ~ \(bind: "^qa_ui_\(run)_[0-9]+$")
            """).all(decoding: U.self).map(\.id)
        TestCodeSink.shared.forgetRun(run)
        guard !ids.isEmpty else { return Deleted(users: 0, steps: []) }
        // Uploads aren't tied to a user, only referenced: collect the run's
        // before the rows that point at them go.
        struct P: Decodable { let path: String }
        let uploads = try await req.db.sql().raw("""
            SELECT unnest(image_urls) AS path FROM posts WHERE author_id = ANY(\(bind: ids)) AND image_urls IS NOT NULL
            UNION SELECT unnest(li.image_urls) FROM listing_items li
              JOIN listing_posts lp ON lp.id = li.listing_id JOIN posts p ON p.id = lp.post_id
              WHERE p.author_id = ANY(\(bind: ids))
            UNION SELECT cover_url FROM communities WHERE created_by = ANY(\(bind: ids)) AND cover_url IS NOT NULL
            """).all(decoding: P.self).map(\.path)
        let steps = try await req.db.withTransaction { t in
            // Cases about the run's content or accounts: `target_id` has no foreign
            // key and `author_id` only goes NULL, so they'd outlive the users.
            try await t.raw("""
                DELETE FROM moderation_cases
                WHERE author_id = ANY(\(bind: ids)) OR (target_type = 'user' AND target_id = ANY(\(bind: ids)))
                """).run()
            // Kept copies and deal records have no foreign key to users on
            // purpose (the law keeps them after a real account is deleted), so
            // a test run removes its own.
            try await t.raw("""
                DELETE FROM deal_records WHERE seller_id = ANY(\(bind: ids)) OR buyer_id = ANY(\(bind: ids))
                """).run()
            try await t.raw("DELETE FROM listing_archive WHERE seller_id = ANY(\(bind: ids))").run()
            var lines = try await SeedDemoCommand.deleteAccounts(ids, on: t)
            lines += try await SeedDemoCommand.recountCounters(on: t)
            return lines
        }
        removeUploads(uploads)
        req.logger.info("uitest: deleted run \(run) (\(ids.count) accounts, \(uploads.count) uploads)")
        return Deleted(users: ids.count, steps: steps)
    }

    /// Each `/uploads/<name>` file and its `<base>_t.jpg` feed copy. Only bare
    /// one-segment names, so a stored path can't reach outside the folder.
    static func removeUploads(_ paths: [String]) {
        for path in paths {
            guard path.hasPrefix("/uploads/") else { continue }
            let name = String(path.dropFirst("/uploads/".count))
            guard !name.isEmpty, !name.contains("/"), !name.hasPrefix(".") else { continue }
            let base = (name as NSString).deletingPathExtension
            for file in [name, "\(base)_t.jpg"] {
                try? FileManager.default.removeItem(atPath: "\(UploadsController.uploadDir)/\(file)")
            }
        }
    }
}

/// The plaintext of the last code mailed to each address, kept in memory on
/// the UI-test server only (`Mailer.codeSink`).
final class TestCodeSink: @unchecked Sendable {
    static let shared = TestCodeSink()
    private let lock = NIOLock()
    private var codes: [String: String] = [:]

    func record(_ code: String, for email: String) {
        lock.withLock { codes[email.lowercased()] = code }
    }

    func last(for email: String) -> String? {
        lock.withLock { codes[email.lowercased()] }
    }

    func forgetRun(_ run: String) {
        lock.withLock { codes = codes.filter { !$0.key.hasPrefix("qa_ui_\(run)_") } }
    }
}

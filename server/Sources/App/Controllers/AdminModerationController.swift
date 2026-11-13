import Vapor
import SQLKit

/// `/api/admin/moderation/*` — the app-wide review queue (migration 089):
/// cases to approve or deny, and appeals against earlier decisions.
struct AdminModerationController {
    static func register(routes: any RoutesBuilder) {
        let m = routes.grouped("admin", "moderation").grouped(AuthMiddleware()).grouped(AppRoleMiddleware())
        m.get("cases", use: listCases)
        m.get("cases", ":id", use: getCase)
        m.post("cases", ":id", "decide", use: decide)
        m.get("appeals", use: listAppeals)
        m.post("appeals", ":id", "decide", use: decideAppeal)
    }

    static func listCases(_ req: Request) async throws -> DataResponse<[ModerationQueue.CaseRow]> {
        let status = (try? req.query.get(String.self, at: "status")) ?? "open"
        guard ["open", "actioned", "dismissed"].contains(status) else { throw InlineError(.badRequest, "Unknown status") }
        let source = try? req.query.get(String.self, at: "source")
        if let source, !["report", "auto"].contains(source) { throw InlineError(.badRequest, "Unknown source") }
        let limit = PostsController.clamp(try? req.query.get(Int.self, at: "limit"), 20, 1, 50)
        let offset = max(0, (try? req.query.get(Int.self, at: "offset")) ?? 0)
        return DataResponse(data: try await ModerationQueue.cases(status: status, source: source, limit: limit,
                                                                  offset: offset, on: req.db.sql()))
    }

    static func getCase(_ req: Request) async throws -> DataResponse<ModerationQueue.CaseDetail> {
        guard let id = uuidParam(req, "id"),
              let detail = try await ModerationQueue.detail(id, on: req.db.sql()) else {
            throw InlineError(.notFound, "Case not found")
        }
        return DataResponse(data: detail)
    }

    /// `note` is staff-only; `reporter_message` is what the reporters read.
    /// A restriction's length is `hours` (6, 12 or whole days); older apps send `days`.
    struct DecideBody: Content { var decision: String?; var days: Int?; var hours: Int?; var note: String?; var reporter_message: String? }

    static func decide(_ req: Request) async throws -> DataResponse<ModerationQueue.CaseDetail> {
        guard let id = uuidParam(req, "id") else { throw InlineError(.notFound, "Case not found") }
        let b = try req.content.decode(DecideBody.self)
        guard let decision = b.decision.flatMap(ModerationDecision.init(rawValue:)) else {
            throw InlineError(.badRequest, "decision must be keep, remove, remove_strike, restrict or ban")
        }
        let outcome = try await ModerationService.decide(caseID: id, decision: decision,
                                                         restrictHours: decision == .restrict ? (b.hours ?? b.days.map { $0 * 24 }) : nil,
                                                         note: try note(b.note), reporterMessage: try note(b.reporter_message),
                                                         actor: req.userID,
                                                         banDays: decision == .ban ? b.days : nil, on: req.db)
        NotifyService.fireAndForget(req) { db, hub, log in await ModerationNotices.decided(outcome, on: db, hub: hub, logger: log) }
        ModerationNotices.email(outcome, app: req.application, logger: req.logger)
        return DataResponse(data: try await ModerationQueue.detail(id, on: req.db.sql())!)
    }

    static func listAppeals(_ req: Request) async throws -> DataResponse<[ModerationQueue.AppealItem]> {
        let status = (try? req.query.get(String.self, at: "status")) ?? "pending"
        guard ["pending", "upheld", "overturned"].contains(status) else { throw InlineError(.badRequest, "Unknown status") }
        let limit = PostsController.clamp(try? req.query.get(Int.self, at: "limit"), 20, 1, 50)
        let offset = max(0, (try? req.query.get(Int.self, at: "offset")) ?? 0)
        return DataResponse(data: try await ModerationQueue.appeals(status: status, limit: limit, offset: offset, on: req.db.sql()))
    }

    struct AppealDecideBody: Content { var result: String?; var note: String?; var reporter_message: String? }

    static func decideAppeal(_ req: Request) async throws -> DataResponse<ModerationQueue.CaseDetail> {
        guard let id = uuidParam(req, "id") else { throw InlineError(.notFound, "Appeal not found") }
        let b = try req.content.decode(AppealDecideBody.self)
        guard let result = b.result, ["uphold", "overturn"].contains(result) else {
            throw InlineError(.badRequest, "result must be uphold or overturn")
        }
        let outcome = try await ModerationService.decideAppeal(id, overturn: result == "overturn", note: try note(b.note),
                                                               reporterMessage: try note(b.reporter_message),
                                                               actor: req.userID, on: req.db)
        NotifyService.fireAndForget(req) { db, hub, log in await ModerationNotices.appealDecided(outcome, on: db, hub: hub, logger: log) }
        return DataResponse(data: try await ModerationQueue.detail(outcome.caseID, on: req.db.sql())!)
    }

    static func uuidParam(_ req: Request, _ name: String) -> String? {
        req.parameters.get(name).flatMap(UUID.init(uuidString:))?.uuidString.lowercased()
    }

    private static func note(_ raw: String?) throws -> String? {
        let n = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (n?.count ?? 0) <= 1000 else { throw InlineError(.badRequest, "Notes can be up to 1000 characters") }
        return (n?.isEmpty ?? true) ? nil : n
    }
}

/// `GET /api/account-status` — like Meta's Account Status: restrictions,
/// strikes, decisions on your content (with appeals), and how your reports
/// ended. Open to banned accounts (see AuthMiddleware.openToBanned).
struct AccountStatusController {
    static func register(routes: any RoutesBuilder) {
        routes.grouped("account-status").grouped(AuthMiddleware()).get(use: get)
    }

    /// A warning (migration 106): its mode, and the item it was for.
    struct Strike: Content {
        var policy: String; var created_at: Date; var expires_at: Date
        @NullCoded var mode: String?
        @NullCoded var case_id: String?
        @NullCoded var target_type: String?
        var snapshot: JSONValue?
    }
    /// An active ban in one mode, with the reason and what it was for.
    struct Ban: Content {
        var mode: String; var banned_at: Date
        @NullCoded var banned_until: Date?
        @NullCoded var policy: String?
        @NullCoded var note: String?
        @NullCoded var case_id: String?
        @NullCoded var target_type: String?
        var snapshot: JSONValue?
    }
    struct Decision: Content {
        var case_id: String; var target_type: String; var policy: String; var decision: String
        var decided_at: Date; var snapshot: JSONValue
        @NullCoded var appeal_status: String?
        var can_appeal: Bool
    }
    struct MyReport: Content {
        var target_type: String; var reason: String; var created_at: Date
        /// pending, kept, removed, action_taken (a profile banned or warned,
        /// left up) or restored (taken down, then put back on appeal).
        var outcome: String
        /// What was reported, so the app can open it: the post (a comment's
        /// post too), profile or community.
        var target_id: String
        @NullCoded var post_id: String?
        /// The content as moderators saw it, for when it's been removed.
        @NullCoded var snapshot: JSONValue?
        /// What the moderator chose to tell reporters, once decided. Their
        /// private note (`decision_note`) never reaches here.
        @NullCoded var reporter_message: String?
        /// The community it happened in, or the community itself when that
        /// was reported, so a community's post reads apart from a post.
        @NullCoded var community_name: String?
    }
    struct Status: Content {
        /// user, moderator or admin — the app shows its Moderation screen to staff.
        var app_role: String
        /// The longest running restriction, any mode; `restrictions` has each.
        @NullCoded var restricted_until: Date?
        var restrictions: [AccountRestrictions.Entry]
        @NullCoded var banned_at: Date?
        @NullCoded var ban_reason: String?
        var strikes: [Strike]
        /// Active bans, per mode; banned in every mode is the whole account.
        var bans: [Ban]
        var decisions: [Decision]
        var reports: [MyReport]
    }

    static func get(_ req: Request) async throws -> DataResponse<Status> {
        let db = req.db.sql(), me = req.userID
        struct U: Decodable { let app_role: String; let banned_at: Date?; let ban_reason: String? }
        let u = try await db.raw("""
            SELECT app_role, banned_at, ban_reason FROM users WHERE id = \(uuid: me)
            """).first(decoding: U.self)
        let restricted = try await AccountRestrictions.active(me, on: db)
        struct S: Decodable {
            let policy: String; let created_at: Date; let expires_at: Date; let mode: String?
            let case_id: String?; let target_type: String?; let snapshot: String?
        }
        func json(_ s: String?) -> JSONValue? { s.flatMap { try? JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) } }
        let strikes = try await db.raw("""
            SELECT s.policy, s.created_at, s.expires_at, s.mode, mc.id::text AS case_id, mc.target_type,
              mc.snapshot::text AS snapshot
            FROM moderation_strikes s LEFT JOIN moderation_cases mc ON mc.id = s.case_id
            WHERE s.user_id = \(uuid: me) AND s.revoked_at IS NULL AND s.expires_at > NOW() ORDER BY s.created_at DESC
            """).all(decoding: S.self).map {
                Strike(policy: $0.policy, created_at: $0.created_at, expires_at: $0.expires_at, mode: $0.mode,
                       case_id: $0.case_id, target_type: $0.target_type, snapshot: json($0.snapshot))
            }
        struct B: Decodable {
            let mode: String; let banned_at: Date; let banned_until: Date?; let policy: String?; let note: String?
            let case_id: String?; let target_type: String?; let snapshot: String?
        }
        let bans = try await db.raw("""
            SELECT ab.mode, ab.banned_at, ab.banned_until, mc.policy, mc.decision_note AS note,
              mc.id::text AS case_id, mc.target_type, mc.snapshot::text AS snapshot
            FROM account_bans ab LEFT JOIN moderation_cases mc ON mc.id = ab.case_id
            WHERE ab.user_id = \(uuid: me) AND ab.lifted_at IS NULL AND (ab.banned_until IS NULL OR ab.banned_until > NOW())
            ORDER BY ab.mode
            """).all(decoding: B.self).map {
                Ban(mode: $0.mode, banned_at: $0.banned_at, banned_until: $0.banned_until, policy: $0.policy, note: $0.note,
                    case_id: $0.case_id, target_type: $0.target_type, snapshot: json($0.snapshot))
            }
        struct D: Decodable {
            let case_id: String; let target_type: String; let policy: String; let decision: String
            let decided_at: Date; let snapshot: String; let appeal_status: String?
        }
        let decisions = try await db.raw("""
            SELECT mc.id::text AS case_id, mc.target_type, mc.policy, mc.decision, mc.decided_at, mc.snapshot::text AS snapshot,
              a.status AS appeal_status
            FROM moderation_cases mc LEFT JOIN moderation_appeals a ON a.case_id = mc.id
            WHERE mc.author_id = \(uuid: me) AND mc.status = 'actioned'
            ORDER BY mc.decided_at DESC LIMIT 50
            """).all(decoding: D.self).map {
                Decision(case_id: $0.case_id, target_type: $0.target_type, policy: $0.policy, decision: $0.decision,
                         decided_at: $0.decided_at,
                         snapshot: try JSONDecoder().decode(JSONValue.self, from: Data($0.snapshot.utf8)),
                         appeal_status: $0.appeal_status,
                         can_appeal: $0.appeal_status == nil && Enforcement.canAppeal(decidedAt: $0.decided_at))
            }
        struct R: Decodable {
            let target_type: String; let reason: String; let created_at: Date; let outcome: String
            let target_id: String; let post_id: String?; let snapshot: String?; let reporter_message: String?
            let community_name: String?
        }
        // App cases, plus reports only a community's staff judged (a
        // community-only reason opens no app case). A report filed into both
        // shows once, as the app case.
        let reports = try await db.raw("""
            SELECT * FROM (
              SELECT r.target_type, r.reason, r.created_at,
                \(unsafeRaw: ReportOutcome.sql) AS outcome,
                r.target_id::text AS target_id,
                CASE r.target_type WHEN 'post' THEN r.target_id::text
                  WHEN 'comment' THEN (SELECT cm.post_id::text FROM comments cm WHERE cm.id = r.target_id) END AS post_id,
                mc.snapshot::text AS snapshot,
                CASE WHEN mc.status IN ('actioned', 'dismissed') THEN NULLIF(btrim(mc.reporter_message), '') END AS reporter_message,
                (SELECT c.name FROM communities c
                 WHERE c.id = CASE WHEN r.target_type = 'community' THEN r.target_id ELSE mc.community_id END) AS community_name
              FROM content_reports r JOIN moderation_cases mc ON mc.id = r.case_id
              WHERE r.reporter_id = \(uuid: me)
              UNION ALL
              SELECT CASE cr.target_type WHEN 'member' THEN 'user' ELSE cr.target_type END, cr.reason, cr.created_at,
                CASE cr.status WHEN 'dismissed' THEN 'kept'
                  WHEN 'resolved' THEN CASE cr.target_type WHEN 'member' THEN 'action_taken' ELSE 'removed' END
                  ELSE 'pending' END,
                cr.target_id::text,
                CASE cr.target_type WHEN 'post' THEN cr.target_id::text END,
                NULL, NULL, c.name
              FROM community_reports cr JOIN communities c ON c.id = cr.community_id
              WHERE cr.reporter_id = \(uuid: me)
                AND NOT EXISTS (SELECT 1 FROM content_reports r2
                                WHERE r2.reporter_id = cr.reporter_id AND r2.target_id = cr.target_id)
            ) mine ORDER BY created_at DESC LIMIT 50
            """).all(decoding: R.self).map {
                MyReport(target_type: $0.target_type, reason: $0.reason, created_at: $0.created_at, outcome: $0.outcome,
                         target_id: $0.target_id, post_id: $0.post_id, snapshot: json($0.snapshot),
                         reporter_message: $0.reporter_message, community_name: $0.community_name)
            }
        return DataResponse(data: Status(app_role: u?.app_role ?? "user", restricted_until: restricted.values.max(),
                                         restrictions: AccountRestrictions.entries(restricted), banned_at: u?.banned_at, ban_reason: u?.ban_reason,
                                         strikes: strikes, bans: bans, decisions: decisions, reports: reports))
    }
}

/// `POST /api/appeals` — the author asks for a second look at a decision.
/// Open to banned accounts (see AuthMiddleware.openToBanned).
struct AppealsController {
    static func register(routes: any RoutesBuilder) {
        routes.grouped("appeals").grouped(AuthMiddleware()).grouped(RateLimitMiddleware.reports())
            .post(use: file)
    }

    struct Body: Content { var case_id: String?; var message: String? }
    struct Filed: Content { var received: Bool }

    static func file(_ req: Request) async throws -> Response {
        let b = try req.content.decode(Body.self)
        guard let caseID = b.case_id.flatMap(UUID.init(uuidString:))?.uuidString.lowercased() else {
            throw InlineError(.badRequest, "Invalid case id")
        }
        let message = b.message?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (message?.count ?? 0) <= 1000 else { throw InlineError(.badRequest, "Your message can be up to 1000 characters") }
        try await ModerationService.fileAppeal(caseID: caseID, user: req.userID,
                                               message: (message?.isEmpty ?? true) ? nil : message, on: req.db.sql())
        return try await ConnectionsController.encode(DataResponse(data: Filed(received: true)), req, .created)
    }
}

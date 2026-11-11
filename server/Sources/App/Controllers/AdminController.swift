import Vapor
import SQLKit

/// The official account's admin tools beyond the moderation queue: overall
/// counts and looking up one account. Admin only (moderators get a 404), and
/// nothing private: no email, phone, birthday or messages.
struct AdminController {
    static func register(routes: any RoutesBuilder) {
        let a = routes.grouped("admin").grouped(AuthMiddleware())
            .grouped(AppRoleMiddleware(adminOnly: true)).grouped(RateLimitMiddleware.admin())
        a.get("stats", use: stats)
        a.get("users", "lookup", use: lookup)
        a.post("moderate", use: moderate)
        a.get("warnings", use: warnings)
    }

    struct ModerateBody: Content {
        var action: String?        // "ban" | "warn"
        var target_type: String?   // user | post | comment | message
        var target_id: String?
        var mode: String?          // for a user: the persona being acted on
        var policy: String?
        var days: Int?             // ban length: 7, 30, 90, 365; nil = permanent
        var note: String?
    }
    struct Moderated: Content {
        var case_id: String
        var decision: String
        var active_warnings: Int
    }

    /// POST /api/admin/moderate: the official account bans or warns from any
    /// post, comment, message or profile. It goes through a case like any
    /// moderation decision, so the person is told why and can appeal. A 3rd
    /// active warning in a mode must be sent as a ban (409 `third_warning`).
    static func moderate(_ req: Request) async throws -> Moderated {
        let b = try req.content.decode(ModerateBody.self)
        guard let action = b.action, ["ban", "warn"].contains(action) else { throw InlineError(.badRequest, "action must be ban or warn") }
        guard let type = b.target_type.flatMap(ReportTarget.init(rawValue:)),
              [.user, .post, .comment, .message].contains(type) else { throw InlineError(.badRequest, "Invalid target type") }
        guard let id = b.target_id.flatMap(UUID.init(uuidString:))?.uuidString.lowercased() else {
            throw InlineError(.badRequest, "Invalid target id")
        }
        guard let policy = b.policy.flatMap(ModerationPolicy.init(rawValue:)) else { throw InlineError(.badRequest, "Invalid reason") }
        guard AccountBans.validDays(b.days) else { throw InlineError(.badRequest, "Ban for 7, 30, 90 or 365 days, or permanently") }
        if let note = b.note, note.count > 500 { throw InlineError(.badRequest, "Note must be at most 500 characters") }
        var mode: String?
        if type == .user {
            guard let m = b.mode, AccountBans.modes.contains(m) else { throw InlineError(.badRequest, "mode must be hobby or work") }
            mode = m
        }
        let db = req.db.sql()
        guard let target = try await ModerationStore.target(type, id, mode: mode, reporter: req.userID, on: db) else {
            throw InlineError(.notFound, "This content is no longer available")
        }
        guard let author = target.author_id, author != req.userID else {
            throw InlineError(.badRequest, "You can't ban or warn yourself")
        }
        // A warning counts in the item's mode; a message (no mode) counts in both.
        let countMode = target.mode ?? mode
        let before: Int
        if let countMode {
            before = try await AccountBans.activeWarnings(author, mode: countMode, on: db)
        } else {
            let hobby = try await AccountBans.activeWarnings(author, mode: "hobby", on: db)
            before = max(hobby, try await AccountBans.activeWarnings(author, mode: "work", on: db))
        }
        if action == "warn" && before + 1 >= AccountBans.warningsForBan {
            throw InlineError(.conflict, "third_warning")
        }
        let caseID = try await ModerationStore.openAdminCase(type: type, id: id, target: target, policy: policy, on: db)
        let outcome = try await ModerationService.decide(
            caseID: caseID, decision: action == "ban" ? .ban : .warn, restrictDays: nil,
            note: b.note?.trimmedText.nilIfEmpty, actor: req.userID, banDays: b.days, on: req.db)
        NotifyService.fireAndForget(req) { db, hub, log in await ModerationNotices.decided(outcome, on: db, hub: hub, logger: log) }
        ModerationNotices.email(outcome, app: req.application, logger: req.logger)
        return Moderated(case_id: caseID, decision: outcome.decision.rawValue, active_warnings: before + 1)
    }

    struct WarningCount: Content { var active_warnings: Int; var banned: Bool }

    /// GET /api/admin/warnings?user_id=&mode= : for the Ban/Warn sheet.
    static func warnings(_ req: Request) async throws -> WarningCount {
        guard let user = (try? req.query.get(String.self, at: "user_id")).flatMap(UUID.init(uuidString:))?.uuidString.lowercased(),
              let mode = try? req.query.get(String.self, at: "mode"), AccountBans.modes.contains(mode) else {
            throw InlineError(.badRequest, "user_id and mode are required")
        }
        let db = req.db.sql()
        return WarningCount(active_warnings: try await AccountBans.activeWarnings(user, mode: mode, on: db),
                            banned: try await AccountBans.activeModes(user, on: db).contains(mode))
    }

    /// Hobby and Work are separate datasets, so every per-mode count is split.
    struct ModeCounts: Content { var hobby: Int; var work: Int }
    struct Stats: Content {
        var accounts: Int
        var new_accounts_7d: Int
        var profiles: ModeCounts
        var posts: ModeCounts
        var posts_7d: ModeCounts
        var open_cases: Int
        var pending_appeals: Int
        var reports_7d: Int
    }

    static func stats(_ req: Request) async throws -> DataResponse<Stats> {
        struct Row: Decodable {
            let accounts: Int; let new_accounts_7d: Int
            let hobby_profiles: Int; let work_profiles: Int
            let hobby_posts: Int; let work_posts: Int; let hobby_posts_7d: Int; let work_posts_7d: Int
            let open_cases: Int; let pending_appeals: Int; let reports_7d: Int
        }
        guard let r = try await req.db.sql().raw("""
            WITH u AS (SELECT created_at, hobby_display_name, work_display_name FROM users WHERE deleted_at IS NULL),
                 p AS (SELECT mode, created_at FROM posts WHERE status = 'posted')
            SELECT
              (SELECT COUNT(*) FROM u)::int AS accounts,
              (SELECT COUNT(*) FROM u WHERE created_at > NOW() - INTERVAL '7 days')::int AS new_accounts_7d,
              (SELECT COUNT(*) FROM u WHERE hobby_display_name IS NOT NULL)::int AS hobby_profiles,
              (SELECT COUNT(*) FROM u WHERE work_display_name IS NOT NULL)::int AS work_profiles,
              (SELECT COUNT(*) FROM p WHERE mode = 'hobby')::int AS hobby_posts,
              (SELECT COUNT(*) FROM p WHERE mode = 'work')::int AS work_posts,
              (SELECT COUNT(*) FROM p WHERE mode = 'hobby' AND created_at > NOW() - INTERVAL '7 days')::int AS hobby_posts_7d,
              (SELECT COUNT(*) FROM p WHERE mode = 'work' AND created_at > NOW() - INTERVAL '7 days')::int AS work_posts_7d,
              (SELECT COUNT(*) FROM moderation_cases WHERE status = 'open')::int AS open_cases,
              (SELECT COUNT(*) FROM moderation_appeals WHERE status = 'pending')::int AS pending_appeals,
              (SELECT COUNT(*) FROM content_reports WHERE created_at > NOW() - INTERVAL '7 days')::int AS reports_7d
            """).first(decoding: Row.self) else { throw Abort(.internalServerError) }
        return DataResponse(data: Stats(
            accounts: r.accounts, new_accounts_7d: r.new_accounts_7d,
            profiles: .init(hobby: r.hobby_profiles, work: r.work_profiles),
            posts: .init(hobby: r.hobby_posts, work: r.work_posts),
            posts_7d: .init(hobby: r.hobby_posts_7d, work: r.work_posts_7d),
            open_cases: r.open_cases, pending_appeals: r.pending_appeals, reports_7d: r.reports_7d))
    }

    struct LookedUp: Content {
        var id: String
        var username: String
        @NullCoded var hobby_display_name: String?
        @NullCoded var work_display_name: String?
        var app_role: String
        var created_at: Date
        @NullCoded var deleted_at: Date?
        @NullCoded var banned_at: Date?
        @NullCoded var restricted_until: Date?
        var active_strikes: Int
        var posts: Int
        var open_cases: Int
    }

    /// GET /api/admin/users/lookup?username=  (with or without the @)
    static func lookup(_ req: Request) async throws -> DataResponse<LookedUp> {
        let raw = (try? req.query.get(String.self, at: "username")) ?? ""
        let name = raw.trimmingCharacters(in: CharacterSet(charactersIn: "@ ")).lowercased()
        guard name.range(of: "^[a-z0-9_]{3,30}$", options: .regularExpression) != nil else {
            throw InlineError(.badRequest, "Username must be 3-30 characters: lowercase letters, numbers, underscore")
        }
        guard let user = try await req.db.sql().raw("""
            SELECT u.id::text AS id, u.username, u.hobby_display_name, u.work_display_name, u.app_role,
              u.created_at, u.deleted_at, u.banned_at,
              GREATEST(\(unsafeRaw: AccountRestrictions.untilSQL("u.id", mode: "hobby")), \(unsafeRaw: AccountRestrictions.untilSQL("u.id", mode: "work"))) AS restricted_until,
              (SELECT COUNT(*) FROM moderation_strikes s
                 WHERE s.user_id = u.id AND s.revoked_at IS NULL AND s.expires_at > NOW())::int AS active_strikes,
              (SELECT COUNT(*) FROM posts p WHERE p.author_id = u.id AND p.status = 'posted')::int AS posts,
              (SELECT COUNT(*) FROM moderation_cases c WHERE c.author_id = u.id AND c.status = 'open')::int AS open_cases
            FROM users u WHERE u.username = \(bind: name)
            """).first(decoding: LookedUp.self) else {
            throw InlineError(.notFound, "User not found")
        }
        return DataResponse(data: user)
    }
}

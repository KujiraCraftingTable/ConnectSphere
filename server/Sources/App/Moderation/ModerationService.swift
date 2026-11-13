import Vapor
import SQLKit

/// Decisions on cases and appeals: take content down or put it back, strikes,
/// restrictions and bans, all in one transaction and written to the audit log.
enum ModerationService {
    struct OpenCase: Decodable {
        let id: String; let target_type: String; let target_id: String
        let author_id: String?; let mode: String?; let policy: String
        let status: String; let auto_hidden: Bool
        let decision: String?; let decided_by: String?; let decided_at: Date?
        let snapshot: String
    }

    /// What happened, for the notices sent afterwards.
    struct Outcome: Sendable {
        let caseID: String
        let decision: ModerationDecision
        let authorID: String?
        /// How long the account was restricted for, in hours.
        let restrictedHours: Int?
    }

    static func loadCase(_ id: String, on db: any SQLDatabase) async throws -> OpenCase? {
        try await db.raw("""
            SELECT id::text AS id, target_type, target_id::text AS target_id, author_id::text AS author_id, mode, policy,
              status, auto_hidden, decision, decided_by::text AS decided_by, decided_at, snapshot::text AS snapshot
            FROM moderation_cases WHERE id = \(uuid: id)
            """).first(decoding: OpenCase.self)
    }

    // MARK: cases

    /// `banDays`: for a ban, how long (one of `AccountBans.allowedDays`); nil is permanent.
    /// `restrictHours`: for a restrict decision, 6, 12 or whole days (see `Enforcement.isValidRestriction`).
    static func decide(caseID: String, decision asked: ModerationDecision, restrictHours: Int?, note: String?,
                       reporterMessage: String? = nil,
                       actor: String, banDays: Int? = nil, on app: AppDatabase) async throws -> Outcome {
        let db = app.sql()
        guard let c = try await loadCase(caseID, on: db) else { throw InlineError(.notFound, "Case not found") }
        guard c.status == "open" else { throw InlineError(.conflict, "This case has already been decided") }
        let policy = ModerationPolicy(rawValue: c.policy) ?? .other
        let decision = Enforcement.escalate(asked, policy: policy)
        if decision == .restrict {
            guard let h = restrictHours, Enforcement.isValidRestriction(hours: h) else {
                throw InlineError(.badRequest, "Restrict for 6 or 12 hours, or 1–\(Enforcement.maxRestrictDays) days")
            }
        }
        if decision != .keep && c.author_id == nil {
            // The account is gone; only the content can be taken down.
            guard decision == .remove else { throw InlineError(.badRequest, "The author's account no longer exists") }
        }

        guard AccountBans.validDays(banDays) else { throw InlineError(.badRequest, "Ban for 7, 30, 90 or 365 days, or permanently") }
        // Banning or warning a profile leaves it as it is: the ban hides the
        // persona while it lasts, and a temporary ban must give it back whole.
        let takesDown = decision.removesContent
            && !(c.target_type == ReportTarget.user.rawValue && (decision == .ban || decision == .warn))
        // A case with no mode (a message) bans in both modes.
        let banModes = c.mode.map { [$0] } ?? AccountBans.modes

        let box = ResultBox()
        try await app.tx { t in
            if takesDown {
                try await takeDown(c, on: t)
            } else if c.auto_hidden {
                try await restore(c, on: t)
            }
            // A job hidden by its reports (migration 126) shows again when kept.
            if !takesDown, c.target_type == ReportTarget.post.rawValue {
                try await HRStore.unhide(postID: c.target_id, on: t)
            }
            try await t.raw("""
                UPDATE moderation_cases SET status = \(bind: decision == .keep ? "dismissed" : "actioned"),
                  decision = \(bind: decision.rawValue), decision_note = \(bind: note),
                  reporter_message = \(bind: reporterMessage), decided_by = \(uuid: actor),
                  decided_at = NOW(), updated_at = NOW()
                WHERE id = \(uuid: caseID)
                """).run()

            var hours: Int?
            if let author = c.author_id {
                switch decision {
                case .keep, .remove: break
                case .removeStrike:
                    hours = try await addStrike(author, caseID: caseID, policy: policy, mode: c.mode, on: t)
                case .warn:
                    try await addWarning(author, caseID: caseID, policy: policy, mode: c.mode, on: t)
                case .restrict:
                    hours = restrictHours
                    try await restrictAccount(author, hours: restrictHours!, caseID: caseID, mode: c.mode, on: t)
                case .ban:
                    try await addWarning(author, caseID: caseID, policy: policy, mode: c.mode, on: t)
                    try await AccountBans.ban(author, modes: banModes, caseID: caseID, days: banDays, on: t)
                }
            }
            var detail = ["decision": decision.rawValue]
            if let hours {
                detail["restricted_hours"] = String(hours)
                // Older apps read only days; they get them when the length is whole days.
                if hours % 24 == 0 { detail["restricted_days"] = String(hours / 24) }
            }
            try await ModerationStore.log(caseID: caseID, actor: actor, action: "decided", detail: detail, on: t)
            box.hours = hours
        }
        if takesDown { await MediaScan.banPhotos(in: c.snapshot, policy: policy, on: db) }
        return Outcome(caseID: caseID, decision: decision, authorID: c.author_id, restrictedHours: box.hours)
    }

    /// Records a strike and applies the ladder; returns the restriction in hours, if any.
    private static func addStrike(_ user: String, caseID: String, policy: ModerationPolicy, mode: String?,
                                  on db: any SQLDatabase) async throws -> Int? {
        try await addWarning(user, caseID: caseID, policy: policy, mode: mode, on: db)
        guard let days = Enforcement.restrictionDays(activeStrikes: try await activeStrikes(user, on: db)) else { return nil }
        try await restrictAccount(user, hours: days * 24, caseID: caseID, mode: mode, on: db)
        return days * 24
    }

    /// A strike in `mode` with no restriction ladder: the official account's
    /// warnings count up to a ban instead (`AccountBans.warningsForBan`).
    private static func addWarning(_ user: String, caseID: String, policy: ModerationPolicy, mode: String?,
                                   on db: any SQLDatabase) async throws {
        try await db.raw("""
            INSERT INTO moderation_strikes (user_id, case_id, policy, mode)
            VALUES (\(uuid: user), \(uuid: caseID), \(bind: policy.rawValue), \(bind: mode))
            ON CONFLICT (case_id) DO NOTHING
            """).run()
    }

    static func activeStrikes(_ user: String, on db: any SQLDatabase) async throws -> Int {
        struct N: Decodable { let n: Int }
        return try await db.raw("""
            SELECT COUNT(*)::int AS n FROM moderation_strikes
            WHERE user_id = \(uuid: user) AND revoked_at IS NULL AND expires_at > NOW()
            """).first(decoding: N.self)!.n
    }

    /// In the case's mode, or both for a case with none (a message). Never
    /// shortens a restriction already running there.
    private static func restrictAccount(_ user: String, hours: Int, caseID: String, mode: String?,
                                        on db: any SQLDatabase) async throws {
        try await AccountRestrictions.restrict(user, modes: mode.map { [$0] } ?? AccountBans.modes, caseID: caseID,
                                               until: "NOW() + make_interval(hours => \(bind: hours)::int)", on: db)
    }

    // MARK: taking content down and putting it back

    static func takeDown(_ c: OpenCase, on db: any SQLDatabase) async throws {
        let id = c.target_id
        switch ReportTarget(rawValue: c.target_type) {
        case .post:
            try await banPost(id, on: db)
        case .comment:
            struct R: Decodable { let post_id: String }
            if let r = try await db.raw("""
                UPDATE comments SET status = 'banned' WHERE id = \(uuid: id) AND status = 'posted' RETURNING post_id::text AS post_id
                """).first(decoding: R.self) {
                try await db.raw("UPDATE posts SET comment_count = GREATEST(comment_count - 1, 0) WHERE id = \(uuid: r.post_id)").run()
            }
        case .message:
            // Shown like a recalled message; removed_at tells an appeal it was us.
            try await db.raw("""
                UPDATE messages SET deleted_at = COALESCE(deleted_at, NOW()), removed_at = NOW()
                WHERE id = \(uuid: id) AND removed_at IS NULL
                """).run()
        case .user:
            let p = personaPrefix(c.mode)
            try await db.raw("""
                UPDATE users SET \(unsafeRaw: p)_bio = NULL, \(unsafeRaw: p)_avatar_url = NULL, \(unsafeRaw: p)_cover_url = NULL,
                  updated_at = NOW()
                WHERE id = \(uuid: id)
                """).run()
        case .community:
            try await db.raw("UPDATE communities SET suspended_at = NOW() WHERE id = \(uuid: id)").run()
        case .datingProfile:
            try await db.raw("UPDATE dating_profiles SET moderation_hidden = TRUE WHERE user_id = \(uuid: id)").run()
        case .story:
            // Stories are deleted once expired, so this one can't come back.
            try await db.raw("UPDATE stories SET expires_at = LEAST(expires_at, NOW()) WHERE id = \(uuid: id)").run()
        case .company:
            try await db.raw("""
                UPDATE companies SET about = NULL, logo_url = NULL, cover_url = NULL, updated_at = NOW() WHERE id = \(uuid: id)
                """).run()
        case nil:
            throw InlineError(.internalServerError, "Unknown target type")
        }
    }

    /// 'banned', unlike 'deleted', can't be restored by the author and isn't
    /// purged after 30 days, so an appeal can still bring the post back.
    static func banPost(_ id: String, on db: any SQLDatabase) async throws {
        struct R: Decodable { let author_id: String; let community_id: String?; let was_live: Bool }
        if let r = try await db.raw("""
            UPDATE posts p SET status = 'banned', updated_at = NOW()
            FROM (SELECT id, status FROM posts WHERE id = \(uuid: id) FOR UPDATE) old
            WHERE p.id = old.id AND p.status IN ('posted', 'pending')
            RETURNING p.author_id::text AS author_id, p.community_id::text AS community_id, (old.status = 'posted') AS was_live
            """).first(decoding: R.self), r.was_live {
            try await db.raw("UPDATE users SET post_count = GREATEST(post_count - 1, 0) WHERE id = \(uuid: r.author_id)").run()
            if let cid = r.community_id { try await CommunityStore.incrementPostCount(cid, -1, on: db) }
        }
    }

    /// The inverse of `takeDown`, for a kept auto-hidden item or an overturned
    /// appeal. Cleared profile fields come back from the snapshot, but never
    /// over something the owner has set since.
    static func restore(_ c: OpenCase, on db: any SQLDatabase) async throws {
        let id = c.target_id
        switch ReportTarget(rawValue: c.target_type) {
        case .post:
            struct R: Decodable { let author_id: String; let community_id: String? }
            if let r = try await db.raw("""
                UPDATE posts SET status = 'posted', updated_at = NOW() WHERE id = \(uuid: id) AND status = 'banned'
                RETURNING author_id::text AS author_id, community_id::text AS community_id
                """).first(decoding: R.self) {
                try await db.raw("UPDATE users SET post_count = post_count + 1 WHERE id = \(uuid: r.author_id)").run()
                if let cid = r.community_id { try await CommunityStore.incrementPostCount(cid, 1, on: db) }
            }
        case .comment:
            struct R: Decodable { let post_id: String }
            if let r = try await db.raw("""
                UPDATE comments SET status = 'posted' WHERE id = \(uuid: id) AND status = 'banned' RETURNING post_id::text AS post_id
                """).first(decoding: R.self) {
                try await db.raw("UPDATE posts SET comment_count = comment_count + 1 WHERE id = \(uuid: r.post_id)").run()
            }
        case .message:
            try await db.raw("""
                UPDATE messages SET deleted_at = NULL, removed_at = NULL WHERE id = \(uuid: id) AND removed_at IS NOT NULL
                """).run()
        case .user:
            // A spam-signal pause (auto_hidden on a user case) is lifted with it.
            try await AccountRestrictions.lift(caseID: c.id, on: db)
            let p = personaPrefix(c.mode)
            try await db.raw("""
                UPDATE users u SET
                  \(unsafeRaw: p)_bio        = COALESCE(u.\(unsafeRaw: p)_bio, s.snap->>'bio'),
                  \(unsafeRaw: p)_avatar_url = COALESCE(u.\(unsafeRaw: p)_avatar_url, s.snap->>'avatar_url'),
                  \(unsafeRaw: p)_cover_url  = COALESCE(u.\(unsafeRaw: p)_cover_url, s.snap->>'cover_url')
                FROM (SELECT \(bind: c.snapshot)::jsonb AS snap) s
                WHERE u.id = \(uuid: id)
                """).run()
        case .community:
            try await db.raw("UPDATE communities SET suspended_at = NULL WHERE id = \(uuid: id)").run()
        case .datingProfile:
            try await db.raw("UPDATE dating_profiles SET moderation_hidden = FALSE WHERE user_id = \(uuid: id)").run()
        case .story, nil:
            break
        case .company:
            try await db.raw("""
                UPDATE companies co SET
                  about     = COALESCE(co.about, s.snap->>'about'),
                  logo_url  = COALESCE(co.logo_url, s.snap->>'logo_url'),
                  cover_url = COALESCE(co.cover_url, s.snap->>'cover_url')
                FROM (SELECT \(bind: c.snapshot)::jsonb AS snap) s
                WHERE co.id = \(uuid: id)
                """).run()
        }
    }

    /// Column prefix for a persona; the case's mode only ever holds hobby/work.
    private static func personaPrefix(_ mode: String?) -> String { mode == "work" ? "work" : "hobby" }

    // MARK: appeals

    static func fileAppeal(caseID: String, user: String, message: String?, on db: any SQLDatabase) async throws {
        guard let c = try await loadCase(caseID, on: db), c.author_id == user,
              c.status == "actioned", let decidedAt = c.decided_at else {
            throw InlineError(.notFound, "There's nothing to appeal here")
        }
        guard Enforcement.canAppeal(decidedAt: decidedAt) else {
            throw InlineError(.badRequest, "Appeals are open for \(Enforcement.appealWindowDays) days after a decision")
        }
        do {
            try await db.raw("""
                INSERT INTO moderation_appeals (case_id, user_id, message)
                VALUES (\(uuid: caseID), \(uuid: user), \(bind: message))
                """).run()
        } catch where PGError.isUniqueViolation(error) {
            throw InlineError(.conflict, "You've already asked for a review of this")
        }
        try await ModerationStore.log(caseID: caseID, actor: user, action: "appeal_filed", on: db)
    }

    struct AppealOutcome: Sendable { let caseID: String; let userID: String; let overturned: Bool }

    /// `reporterMessage`, on an overturn, replaces what reporters read about the case.
    static func decideAppeal(_ appealID: String, overturn: Bool, note: String?, reporterMessage: String? = nil,
                             actor: String, on app: AppDatabase) async throws -> AppealOutcome {
        let db = app.sql()
        struct A: Decodable { let case_id: String; let user_id: String; let status: String }
        guard let a = try await db.raw("""
            SELECT case_id::text AS case_id, user_id::text AS user_id, status FROM moderation_appeals WHERE id = \(uuid: appealID)
            """).first(decoding: A.self) else { throw InlineError(.notFound, "Appeal not found") }
        guard a.status == "pending" else { throw InlineError(.conflict, "This appeal has already been decided") }
        guard let c = try await loadCase(a.case_id, on: db) else { throw InlineError(.notFound, "Case not found") }
        // A second pair of eyes when there is one.
        if c.decided_by == actor, try await staffCount(on: db) > 1 {
            throw InlineError(.forbidden, "Another moderator needs to review the appeal of your own decision")
        }
        try await app.tx { t in
            try await t.raw("""
                UPDATE moderation_appeals SET status = \(bind: overturn ? "overturned" : "upheld"),
                  decided_by = \(uuid: actor), decided_at = NOW()
                WHERE id = \(uuid: appealID)
                """).run()
            if overturn {
                try await restore(c, on: t)
                try await t.raw("""
                    UPDATE moderation_cases SET reporter_message = \(bind: reporterMessage), updated_at = NOW()
                    WHERE id = \(uuid: c.id)
                    """).run()
                try await t.raw("UPDATE moderation_strikes SET revoked_at = NOW() WHERE case_id = \(uuid: c.id)").run()
                switch ModerationDecision(rawValue: c.decision ?? "") {
                case .ban:
                    try await AccountBans.lift(caseID: c.id, on: t)
                case .restrict, .removeStrike:
                    // Only what this case restricted; others keep running.
                    try await AccountRestrictions.lift(caseID: c.id, on: t)
                default: break
                }
            }
            var detail = ["result": overturn ? "overturned" : "upheld"]
            if let note { detail["note"] = note }
            try await ModerationStore.log(caseID: c.id, actor: actor, action: "appeal_decided", detail: detail, on: t)
        }
        return AppealOutcome(caseID: c.id, userID: a.user_id, overturned: overturn)
    }

    static func staffCount(on db: any SQLDatabase) async throws -> Int {
        struct N: Decodable { let n: Int }
        return try await db.raw("""
            SELECT COUNT(*)::int AS n FROM users WHERE app_role IN ('moderator', 'admin') AND deleted_at IS NULL
            """).first(decoding: N.self)!.n
    }

    /// Carries a value out of `tx`'s `Void` closure.
    private final class ResultBox: @unchecked Sendable { var hours: Int? }
}

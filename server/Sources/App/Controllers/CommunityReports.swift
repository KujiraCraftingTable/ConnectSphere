import Vapor
import SQLKit

/// A community's Reports screen: its admins and moderators judge reported
/// posts and members the way the app's moderators judge cases, at community
/// level only. Reports on the same post or member are one case; reporters
/// stay anonymous to community staff. Strikes, restrictions and account bans
/// stay with the app's moderators.
extension ReportsController {
    /// What staff may decide, by target. `remove_ban` / `ban` are the admin's alone.
    static let postDecisions: Set<String> = ["keep", "remove", "remove_warn", "remove_ban"]
    static let memberDecisions: Set<String> = ["keep", "ban"]
    static let adminOnlyDecisions: Set<String> = ["remove_ban", "ban"]
    static let maxDecisionNote = 500

    static func registerCommunityReportRoutes(on c: any RoutesBuilder) {
        c.get(":id", "reports", "target", ":targetId", use: reportCase)
        c.patch(":id", "reports", "target", ":targetId", use: decideReportCase)
    }

    // MARK: queue (one row per reported post or member)

    struct ReasonCount: Content { var reason: String; var count: Int }
    struct CaseRow: Content {
        var target_type: String
        var target_id: String
        var report_count: Int
        var reasons: [ReasonCount]
        var latest_at: Date
        /// pending, or how it ended: resolved / dismissed.
        var status: String
        @NullCoded var post_content: String?
        @NullCoded var post_image: String?
        /// The post's author, or the reported member.
        @NullCoded var person_id: String?
        @NullCoded var person_name: String?
        @NullCoded var person_username: String?
        @NullCoded var person_avatar_url: String?
        @NullCoded var person_avatar_color: String?
        /// Earlier removals and warnings of this person in this community.
        var prior_actions: Int
    }
    struct CaseQueue: Content { var cases: [CaseRow]; var pendingCount: Int }

    static func moderationQueue(_ req: Request) async throws -> DataResponse<CaseQueue> {
        let id = req.parameters.get("id")!
        let db = req.db.sql()
        guard CommunitiesController.staff(try await CommunityStore.membership(id, req.userID, on: db)) else {
            throw Abort(.forbidden, reason: "Only admins and moderators can see reports")
        }
        let resolved = (try? req.query.get(String.self, at: "status")) == "resolved"
        let cases = try await caseRows(id, resolved: resolved, target: nil,
                                       limit: req.pageLimit(default: 20, max: 100), offset: req.pageOffset, on: db)
        return DataResponse(data: CaseQueue(cases: cases, pendingCount: try await pendingCaseCount(id, on: db)))
    }

    /// Reported posts and members, one row each, newest report first.
    static func caseRows(_ communityID: String, resolved: Bool, target: String?, limit: Int, offset: Int,
                         on db: any SQLDatabase) async throws -> [CaseRow] {
        let statusFilter: SQLQueryString = resolved ? "r.status IN ('resolved', 'dismissed')" : "r.status = 'pending'"
        let targetFilter: SQLQueryString = target.map { " AND r.target_id = \(uuid: $0)" } ?? ""
        struct Row: Decodable {
            let target_type: String; let target_id: String; let report_count: Int; let reasons: String
            let latest_at: Date; let status: String; let post_content: String?; let post_image: String?
            let person_id: String?; let person_name: String?; let person_username: String?
            let person_avatar_url: String?; let person_avatar_color: String?; let prior_actions: Int
        }
        let rows = try await db.raw("""
            WITH grouped AS (
              SELECT r.target_type, r.target_id, COUNT(*)::int AS report_count, MAX(r.created_at) AS latest_at,
                MAX(r.status) AS status
              FROM community_reports r
              WHERE r.community_id = \(uuid: communityID) AND \(statusFilter)\(targetFilter)
              GROUP BY r.target_type, r.target_id
            )
            SELECT g.target_type, g.target_id::text AS target_id, g.report_count, g.latest_at, g.status,
              (SELECT COALESCE(json_agg(json_build_object('reason', x.reason, 'count', x.n) ORDER BY x.n DESC), '[]'::json)
                 FROM (SELECT r.reason, COUNT(*)::int AS n FROM community_reports r
                       WHERE r.community_id = \(uuid: communityID) AND r.target_id = g.target_id AND \(statusFilter)
                       GROUP BY r.reason) x)::text AS reasons,
              p.content AS post_content, p.image_urls[1] AS post_image,
              u.id::text AS person_id, u.display_name AS person_name, u.username AS person_username,
              u.avatar_url AS person_avatar_url, u.avatar_color AS person_avatar_color,
              (SELECT COUNT(*)::int FROM community_mod_log ml
                 WHERE ml.community_id = \(uuid: communityID) AND ml.target_user_id = u.id
                   AND ml.action IN ('remove_content', 'warn')) AS prior_actions
            FROM grouped g
            LEFT JOIN posts p ON g.target_type = 'post' AND p.id = g.target_id
            LEFT JOIN users u ON u.id = CASE WHEN g.target_type = 'post' THEN p.author_id ELSE g.target_id END
            ORDER BY g.latest_at DESC
            LIMIT \(bind: limit) OFFSET \(bind: offset)
            """).all(decoding: Row.self)
        return rows.map { r in
            CaseRow(target_type: r.target_type, target_id: r.target_id, report_count: r.report_count,
                    reasons: (try? JSONDecoder().decode([ReasonCount].self, from: Data(r.reasons.utf8))) ?? [],
                    latest_at: r.latest_at, status: r.status, post_content: r.post_content, post_image: r.post_image,
                    person_id: r.person_id, person_name: r.person_name, person_username: r.person_username,
                    person_avatar_url: r.person_avatar_url, person_avatar_color: r.person_avatar_color,
                    prior_actions: r.prior_actions)
        }
    }

    /// Reported posts and members waiting for a decision, counted as cases.
    static func pendingCaseCount(_ communityID: String, on db: any SQLDatabase) async throws -> Int {
        struct N: Decodable { let n: Int }
        return try await db.raw("""
            SELECT COUNT(DISTINCT target_id)::int AS n FROM community_reports
            WHERE community_id = \(uuid: communityID) AND status = 'pending'
            """).first(decoding: N.self)?.n ?? 0
    }

    // MARK: one case

    struct CaseReport: Content { var reason: String; @NullCoded var detail: String?; var status: String; var created_at: Date }
    /// The admin or moderator who let the post in. Shown on the case because
    /// staff can approve content that breaks the rules, and the rest of the
    /// team should see who did.
    struct Approver: Content {
        var id: String
        var display_name: String
        var username: String
        @NullCoded var avatar_url: String?
        @NullCoded var avatar_color: String?
        var approved_at: Date
    }
    struct CaseDetail: Content {
        var summary: CaseRow; var reports: [CaseReport]; @NullCoded var approved_by: Approver?
        /// False when the viewer reported this and someone else has to decide it.
        var can_decide: Bool
    }

    /// Staff don't judge reports they filed: another moderator or the admin
    /// does. The admin decides their own report only when there is no
    /// moderator to hand it to.
    static func mayDecide(isReporter: Bool, role: String?, moderatorCount: Int) -> Bool {
        !isReporter || (role == "admin" && moderatorCount == 0)
    }

    static let ownReportMessage = "Another moderator or the admin needs to decide this"

    /// Whether `req.userID` may decide reports filed by `reporters`.
    static func mayDecide(_ communityID: String, reporters: [String], role: String?,
                          _ req: Request, on db: any SQLDatabase) async throws -> Bool {
        let isReporter = reporters.contains { $0.caseInsensitiveCompare(req.userID) == .orderedSame }
        guard isReporter else { return true }
        return mayDecide(isReporter: true, role: role,
                         moderatorCount: try await CommunityStore.countModerators(communityID, on: db))
    }

    static func reportCase(_ req: Request) async throws -> DataResponse<CaseDetail> {
        let id = req.parameters.get("id")!
        let targetID = try targetParam(req)
        let db = req.db.sql()
        guard CommunitiesController.staff(try await CommunityStore.membership(id, req.userID, on: db)) else {
            throw Abort(.forbidden, reason: "Only admins and moderators can see reports")
        }
        // Pending if anything still waits on it, else how it was settled.
        var summary = try await caseRows(id, resolved: false, target: targetID, limit: 1, offset: 0, on: db).first
        if summary == nil {
            summary = try await caseRows(id, resolved: true, target: targetID, limit: 1, offset: 0, on: db).first
        }
        guard let summary else { throw Abort(.notFound, reason: "Report not found") }
        // Reasons and details only: who reported stays private from community staff.
        let reports = try await db.raw("""
            SELECT reason, detail, status, created_at FROM community_reports
            WHERE community_id = \(uuid: id) AND target_id = \(uuid: targetID)
            ORDER BY created_at DESC
            """).all(decoding: CaseReport.self)
        struct Reporter: Decodable { let reporter_id: String }
        let pendingReporters = try await db.raw("""
            SELECT reporter_id::text AS reporter_id FROM community_reports
            WHERE community_id = \(uuid: id) AND target_id = \(uuid: targetID) AND status = 'pending'
            """).all(decoding: Reporter.self).map(\.reporter_id)
        let canDecide = try await mayDecide(id, reporters: pendingReporters,
                                            role: try await CommunityStore.membership(id, req.userID, on: db), req, on: db)
        // A post held for approval, or a Marketplace listing approved into this community.
        let approver = try await db.raw("""
            SELECT u.id::text AS id, u.display_name, u.username, u.avatar_url, u.avatar_color, a.at AS approved_at
            FROM (
              SELECT p.reviewed_by AS uid, p.reviewed_at AS at FROM posts p
              WHERE p.id = \(uuid: targetID) AND p.community_id = \(uuid: id) AND p.reviewed_by IS NOT NULL
              UNION ALL
              SELECT lc.reviewed_by, lc.reviewed_at FROM listing_posts lp
              JOIN listing_communities lc ON lc.listing_id = lp.id
              WHERE lp.post_id = \(uuid: targetID) AND lc.community_id = \(uuid: id)
                AND lc.status = 'posted' AND lc.reviewed_by IS NOT NULL
            ) a JOIN users u ON u.id = a.uid
            LIMIT 1
            """).first(decoding: Approver.self)
        return DataResponse(data: CaseDetail(summary: summary, reports: reports, approved_by: approver, can_decide: canDecide))
    }

    // MARK: decide

    struct DecideBody: Content { var decision: String?; var note: String? }
    struct Decided: Content { var status: String; var resolved: Int }

    static func decideReportCase(_ req: Request) async throws -> DataResponse<Decided> {
        let cid = req.parameters.get("id")!
        let targetID = try targetParam(req)
        let db = req.db.sql()
        let b = try req.content.decode(DecideBody.self)
        let note = b.note?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        if let note, note.count > maxDecisionNote {
            throw Abort(.badRequest, reason: "The note can be up to \(maxDecisionNote) characters")
        }
        let role = try await CommunityStore.membership(cid, req.userID, on: db)
        guard CommunitiesController.staff(role) else {
            throw Abort(.forbidden, reason: "Only admins and moderators can decide reports")
        }

        struct Pending: Decodable { let target_type: String; let reporter_id: String; let reason: String }
        let pending = try await db.raw("""
            SELECT target_type, reporter_id::text AS reporter_id, reason FROM community_reports
            WHERE community_id = \(uuid: cid) AND target_id = \(uuid: targetID) AND status = 'pending'
            """).all(decoding: Pending.self)
        guard let targetType = pending.first?.target_type else {
            throw Abort(.conflict, reason: "These reports have already been reviewed")
        }
        let decision = try validDecision(b.decision, targetType: targetType, role: role)
        guard try await mayDecide(cid, reporters: pending.map(\.reporter_id), role: role, req, on: db) else {
            throw Abort(.forbidden, reason: ownReportMessage)
        }

        // The person behind it: the post's author, or the reported member.
        struct A: Decodable { let author_id: String }
        let person = targetType == "member" ? targetID : try await db.raw(
            "SELECT author_id::text AS author_id FROM posts WHERE id = \(uuid: targetID)"
        ).first(decoding: A.self)?.author_id
        let removes = decision.hasPrefix("remove")
        let warns = decision == "remove_warn"
        let bans = decision == "remove_ban" || decision == "ban"
        if bans {
            guard let person else { throw Abort(.notFound, reason: "That member no longer exists") }
            guard person != req.userID else { throw Abort(.badRequest, reason: "You can't ban yourself") }
        }

        if removes { try await ModerationService.banPost(targetID, on: db) }
        if warns, let person {
            try await db.raw("""
                INSERT INTO community_warnings (community_id, user_id, warned_by, post_id, note)
                VALUES (\(uuid: cid), \(uuid: person), \(uuid: req.userID), \(uuid: targetID), \(bind: note))
                """).run()
        }
        if bans, let person {
            try await req.db.tx { t in
                if try await CommunityStore.kickMember(cid, person, on: t) {
                    try await CommunityStore.incrementMemberCount(cid, -1, on: t)
                }
                try await t.raw("""
                    INSERT INTO community_bans (community_id, user_id, banned_by)
                    VALUES (\(uuid: cid), \(uuid: person), \(uuid: req.userID))
                    ON CONFLICT (community_id, user_id) DO NOTHING
                    """).run()
            }
        }

        let postID = targetType == "post" ? targetID : nil
        var logged: [String] = []
        if removes { logged.append("remove_content") }
        if warns { logged.append("warn") }
        if bans { logged.append("ban") }
        if decision == "keep" { logged.append("resolve_report") }
        for action in logged {
            await CommunityStore.logAction(cid, actor: req.userID, action, targetUser: person, targetPost: postID,
                                           detail: note, on: db)
        }

        let finalStatus = decision == "keep" ? "dismissed" : "resolved"
        try await db.raw("""
            UPDATE community_reports SET status = \(bind: finalStatus), resolved_by = \(uuid: req.userID), resolved_at = NOW()
            WHERE community_id = \(uuid: cid) AND target_id = \(uuid: targetID) AND status = 'pending'
            """).run()

        // The app's own case on a removed post stays open for its moderators,
        // with a note that community staff already took it down.
        if removes {
            struct C: Decodable { let id: String }
            if let appCase = try? await db.raw("""
                SELECT id::text AS id FROM moderation_cases
                WHERE target_type = 'post' AND target_id = \(uuid: targetID) AND status = 'open' LIMIT 1
                """).first(decoding: C.self) {
                try? await ModerationStore.log(caseID: appCase.id, actor: req.userID, action: "community_removed",
                                               detail: ["community_id": cid], on: db)
            }
        }

        let reporters = Array(Set(pending.map(\.reporter_id)))
        let reason = pending.first?.reason ?? "other"
        NotifyService.fireAndForget(req) { db, hub, log in
            if let person, removes {
                await NotifyService.pushUserNotification(userID: person, type: "content_removed", communityID: cid,
                                                         payload: ["reason": reason], on: db, hub: hub, logger: log)
            }
            if let person, warns {
                var payload: [String: Any] = [:]
                if let note { payload["note"] = note }
                await NotifyService.pushUserNotification(userID: person, type: "community_warning", communityID: cid,
                                                         payload: payload, on: db, hub: hub, logger: log)
            }
            // The reported person always hears the outcome too: kept, or
            // removed from the community. Removal and warnings have their own notices above.
            if let person, decision == "keep" || bans {
                await NotifyService.pushUserNotification(
                    userID: person, type: "community_report_result", communityID: cid,
                    payload: ["outcome": bans ? "banned" : "kept", "targetType": targetType],
                    on: db, hub: hub, logger: log)
            }
            for r in reporters {
                await NotifyService.pushUserNotification(
                    userID: r, type: "community_report_outcome", communityID: cid,
                    payload: ["outcome": decision == "keep" ? "kept" : "removed"], on: db, hub: hub, logger: log)
            }
        }
        return DataResponse(data: Decided(status: finalStatus, resolved: pending.count))
    }

    /// The decision, if staff with this role may make it on this kind of target.
    static func validDecision(_ raw: String?, targetType: String, role: String?) throws -> String {
        let allowed = targetType == "post" ? postDecisions : memberDecisions
        guard let decision = raw, allowed.contains(decision) else {
            throw Abort(.badRequest, reason: "decision must be one of: \(allowed.sorted().joined(separator: ", "))")
        }
        if adminOnlyDecisions.contains(decision) && role != "admin" {
            throw Abort(.forbidden, reason: "Only the admin can ban members")
        }
        return decision
    }

    private static func targetParam(_ req: Request) throws -> String {
        guard let t = req.parameters.get("targetId").flatMap(UUID.init(uuidString:)) else {
            throw Abort(.badRequest, reason: "Invalid target id")
        }
        return t.uuidString.lowercased()
    }
}

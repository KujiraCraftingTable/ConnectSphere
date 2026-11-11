import Vapor
import SQLKit

/// Reports. Client errors are thrown as `Abort` ({status,code,message}).
/// A community's staff judge its reports in CommunityReports.swift.
struct ReportsController {
    static let validReasons = ["spam", "harassment", "hate_speech", "misinformation", "off_topic", "other"]
    static let maxDetailLength = 500

    /// Community-scoped routes (mounted by CommunitiesController).
    static func registerCommunityRoutes(on c: any RoutesBuilder) {
        c.post(":id", "members", ":userId", "report", use: reportMember)
        c.get(":id", "moderation", use: moderationQueue)
        c.patch(":id", "reports", ":reportId", use: resolveReport)
        registerCommunityReportRoutes(on: c)
        c.get(":id", "analytics", use: analytics)
    }

    // MARK: app-wide reports (migration 089)

    /// `POST /api/reports` — report anything; see `ReportTarget` for what and why.
    static func register(routes: any RoutesBuilder) {
        routes.grouped("reports").grouped(AuthMiddleware()).grouped(RateLimitMiddleware.reports())
            .post(use: fileReport)
    }

    struct FileBody: Content {
        var target_type: String?; var target_id: String?; var reason: String?
        var detail: String?; var mode: String?
    }
    struct Filed: Content { var received: Bool }

    static func fileReport(_ req: Request) async throws -> Response {
        let b = try req.content.decode(FileBody.self)
        let type: ReportTarget, reason: ModerationPolicy, detail: String?
        do {
            (type, reason, detail) = try ReportRules.validate(target: b.target_type, reason: b.reason, detail: b.detail)
        } catch ReportRules.Problem.badTarget {
            throw InlineError(.badRequest, "Invalid target type")
        } catch ReportRules.Problem.badReason {
            throw InlineError(.badRequest, "Invalid reason")
        } catch {
            throw InlineError(.badRequest, "Details can be up to \(ReportRules.maxDetail) characters")
        }
        guard let id = b.target_id.flatMap(UUID.init(uuidString:))?.uuidString.lowercased() else {
            throw InlineError(.badRequest, "Invalid target id")
        }
        var mode: String?
        if type == .user {
            guard let m = b.mode, ["hobby", "work"].contains(m) else { throw InlineError(.badRequest, "mode must be hobby or work") }
            mode = m
        }
        try await file(req, type: type, id: id, mode: mode, reason: reason, detail: detail)
        return try await ConnectionsController.encode(DataResponse(data: Filed(received: true)), req, .created)
    }

    /// Files a validated report: the item's app case, plus the community
    /// staff's queue for a post in a community.
    static func file(_ req: Request, type: ReportTarget, id: String, mode: String?,
                     reason: ModerationPolicy, detail: String?) async throws {
        let db = req.db.sql()
        guard let target = try await ModerationStore.target(type, id, mode: mode, reporter: req.userID, on: db) else {
            throw InlineError(.notFound, "This content is no longer available")
        }
        if target.author_id == req.userID { throw InlineError(.badRequest, "You can't report your own content") }
        try await OfficialAccount.refuse(target.author_id, "can't be reported", on: db)
        if try await ModerationStore.hasReported(req.userID, type, id, on: db) {
            throw InlineError(.conflict, "You've already reported this")
        }

        // A post in a community: its staff always see the report, and judge
        // house-rule reasons alone. Harm also goes to the app's moderators.
        let inCommunity = type == .post && target.community_id != nil
        if inCommunity, let cid = target.community_id {
            try await ModerationStore.fileCommunityReport(reporter: req.userID, postID: id, communityID: cid,
                                                          reason: reason, detail: detail, on: db)
            // Staff hear about it in a batch: RequestDigestJob.
        }
        if !(inCommunity && ReportRules.communityOnly.contains(reason)) {
            do {
                let filed = try await ModerationStore.fileReport(reporter: req.userID, type: type, id: id, target: target,
                                                                 reason: reason, detail: detail, on: db)
                if filed.opened {
                    try await ModerationStore.log(caseID: filed.case_id, actor: nil, action: "case_opened",
                                                  detail: ["source": "report", "policy": reason.rawValue], on: db)
                }
                // Enough people flagged a job: it hides until the admin decides,
                // so fewer applicants reach a possible scam meanwhile.
                if type == .post { try await HRStore.hideIfReported(postID: id, caseID: filed.case_id, on: db) }
            } catch where PGError.isUniqueViolation(error) {
                throw InlineError(.conflict, "You've already reported this")
            }
        }
        let reporter = req.userID
        let reportedTo = inCommunity ? target.community_id : nil
        NotifyService.fireAndForget(req) { db, hub, log in
            await ModerationNotices.reportReceived(reporter: reporter, type: type, communityID: reportedTo,
                                                   on: db, hub: hub, logger: log)
        }
    }

    // MARK: submit

    struct ReportBody: Content { var reason: String?; var detail: String?; var communityId: String? }
    struct ReportRow: Content {
        var id: String
        var reporter_id: String
        var target_type: String
        var target_id: String
        @NullCoded var community_id: String?
        var reason: String
        @NullCoded var detail: String?
        var status: String
        @NullCoded var resolved_by: String?
        @NullCoded var resolved_at: Date?
        var created_at: Date
    }

    static func submit(reporterID: String, targetType: String, targetID: String, communityID: String?, reason: String?, detail: String?, on db: any SQLDatabase) async throws -> ReportRow {
        guard ["post", "member"].contains(targetType) else { throw Abort(.badRequest, reason: "Invalid target type") }
        guard let reason, validReasons.contains(reason) else { throw Abort(.badRequest, reason: "Invalid reason") }
        if targetType == "member" && targetID.caseInsensitiveCompare(reporterID) == .orderedSame { throw Abort(.badRequest, reason: "You cannot report yourself") }
        if targetType == "member" { try await OfficialAccount.refuse(targetID, "can't be reported", on: db) }
        if let detail, detail.count > maxDetailLength { throw Abort(.badRequest, reason: "Detail must be at most \(maxDetailLength) characters") }

        struct I: Decodable { let id: String }
        if try await db.raw("SELECT id FROM community_reports WHERE reporter_id = \(uuid: reporterID) AND target_type = \(bind: targetType) AND target_id = \(uuid: targetID)")
            .first(decoding: I.self) != nil {
            throw Abort(.conflict, reason: "You have already reported this")
        }
        if targetType == "post" {
            guard let meta = try await PostStore.findMeta(targetID, on: db), meta.community_id == communityID else {
                throw Abort(.notFound, reason: "Post not found in this community")
            }
            if meta.author_id.caseInsensitiveCompare(reporterID) == .orderedSame {
                throw Abort(.badRequest, reason: "You cannot report your own post")
            }
            try await OfficialAccount.refuse(meta.author_id, "can't be reported", on: db)
        } else if let communityID {
            guard try await CommunityStore.membership(communityID, targetID, on: db) != nil else {
                throw Abort(.notFound, reason: "Member not found in this community")
            }
        }
        let row = try await db.raw("""
            INSERT INTO community_reports (reporter_id, target_type, target_id, community_id, reason, detail)
            VALUES (\(uuid: reporterID), \(bind: targetType), \(uuid: targetID), \(uuid: communityID), \(bind: reason), \(bind: detail?.nilIfEmpty))
            RETURNING id::text AS id, reporter_id::text AS reporter_id, target_type, target_id::text AS target_id,
              community_id::text AS community_id, reason, detail, status, resolved_by::text AS resolved_by, resolved_at, created_at
            """).first(decoding: ReportRow.self)!
        return row
    }

    /// POST /api/posts/:id/report  (mounted under /api/posts by PostsController)
    static func reportPost(_ req: Request) async throws -> Response {
        let b = try req.content.decode(ReportBody.self)
        let communityID = (try? req.query.get(String.self, at: "communityId")) ?? b.communityId
        let row = try await submit(reporterID: req.userID, targetType: "post", targetID: req.parameters.get("id")!,
                                   communityID: communityID, reason: b.reason, detail: b.detail, on: req.db.sql())
        return try await ConnectionsController.encode(DataResponse(data: row), req, .created)
    }

    static func reportMember(_ req: Request) async throws -> Response {
        let b = try req.content.decode(ReportBody.self)
        let row = try await submit(reporterID: req.userID, targetType: "member", targetID: req.parameters.get("userId")!,
                                   communityID: req.parameters.get("id")!, reason: b.reason, detail: b.detail, on: req.db.sql())
        return try await ConnectionsController.encode(DataResponse(data: row), req, .created)
    }

    // MARK: resolve

    struct ResolveBody: Content { var action: String? }
    static func resolveReport(_ req: Request) async throws -> DataResponse<ReportRow> {
        let reportID = req.parameters.get("reportId")!
        let db = req.db.sql()
        guard let action = try req.content.decode(ResolveBody.self).action,
              ["remove_content", "ban_member", "dismiss"].contains(action) else {
            throw Abort(.badRequest, reason: "action must be remove_content, ban_member, or dismiss")
        }
        struct RR: Decodable { let id: String; let community_id: String?; let status: String; let target_type: String; let target_id: String; let reason: String; let reporter_id: String }
        guard let report = try await db.raw("SELECT id::text AS id, community_id::text AS community_id, status, target_type, target_id::text AS target_id, reason, reporter_id::text AS reporter_id FROM community_reports WHERE id = \(uuid: reportID)")
            .first(decoding: RR.self) else { throw Abort(.notFound, reason: "Report not found") }
        if report.status != "pending" { throw Abort(.conflict, reason: "Report has already been reviewed") }
        guard let cid = report.community_id else { throw Abort(.badRequest, reason: "Report has no community") }
        let reviewerRole = try await CommunityStore.membership(cid, req.userID, on: db)
        guard CommunitiesController.staff(reviewerRole) else {
            throw Abort(.forbidden, reason: "Only admins and moderators can resolve reports")
        }
        guard try await mayDecide(cid, reporters: [report.reporter_id], role: reviewerRole, req, on: db) else {
            throw Abort(.forbidden, reason: ownReportMessage)
        }
        if action == "remove_content" && report.target_type != "post" {
            throw Abort(.badRequest, reason: "remove_content is only valid for post reports")
        }
        if action == "ban_member" && report.target_type != "member" {
            throw Abort(.badRequest, reason: "ban_member is only valid for member reports")
        }

        if action == "remove_content" {
            // Removed by staff, so the author can't restore it from Recently Deleted.
            struct A: Decodable { let author_id: String }
            let author = try await db.raw("SELECT author_id::text AS author_id FROM posts WHERE id = \(uuid: report.target_id)")
                .first(decoding: A.self)?.author_id
            try await ModerationService.banPost(report.target_id, on: db)
            if let author {
                let reason = report.reason
                NotifyService.fireAndForget(req) { db, hub, log in
                    await NotifyService.pushUserNotification(userID: author, type: "content_removed", communityID: cid,
                                                             payload: ["reason": reason], on: db, hub: hub, logger: log)
                }
            }
        } else if action == "ban_member" {
            // Banning is the admin's alone; moderators remove or dismiss.
            guard reviewerRole == "admin" else { throw Abort(.forbidden, reason: "Only the admin can ban members") }
            try await req.db.tx { t in
                if try await CommunityStore.kickMember(cid, report.target_id, on: t) {
                    try await CommunityStore.incrementMemberCount(cid, -1, on: t)
                }
                try await t.raw("""
                    INSERT INTO community_bans (community_id, user_id, banned_by)
                    VALUES (\(uuid: cid), \(uuid: report.target_id), \(uuid: req.userID))
                    ON CONFLICT (community_id, user_id) DO NOTHING
                    """).run()
            }
        }
        await CommunityStore.logAction(cid, actor: req.userID,
                                       action == "remove_content" ? "remove_content" : action == "ban_member" ? "ban" : "resolve_report",
                                       targetUser: report.target_type == "member" ? report.target_id : nil,
                                       targetPost: report.target_type == "post" ? report.target_id : nil,
                                       detail: action, on: db)
        let finalStatus = action == "dismiss" ? "dismissed" : "resolved"
        let updated = try await db.raw("""
            UPDATE community_reports SET status = \(bind: finalStatus), resolved_by = \(uuid: req.userID), resolved_at = NOW()
            WHERE id = \(uuid: reportID)
            RETURNING id::text AS id, reporter_id::text AS reporter_id, target_type, target_id::text AS target_id,
              community_id::text AS community_id, reason, detail, status, resolved_by::text AS resolved_by, resolved_at, created_at
            """).first(decoding: ReportRow.self)!
        return DataResponse(data: updated)
    }

    // MARK: analytics, deferred to Phase 3 tail (analyticsService)

    static func analytics(_ req: Request) async throws -> DataResponse<AnalyticsPayload> {
        let id = req.parameters.get("id")!
        let db = req.db.sql()
        guard try await CommunityStore.membership(id, req.userID, on: db) == "admin" else {
            throw Abort(.forbidden, reason: "Only admins can view analytics")
        }
        struct C: Decodable { let member_count: Int; let post_count: Int }
        guard let c = try await db.raw("SELECT member_count, post_count FROM communities WHERE id = \(uuid: id)").first(decoding: C.self) else {
            throw Abort(.notFound, reason: "Community not found")
        }
        // Minimal shape until analyticsService is ported.
        return DataResponse(data: AnalyticsPayload(
            totalMembers: c.member_count, totalPosts: c.post_count,
            memberGrowthRate: 0, postGrowthRate: 0, dailySnapshots: [], topPosts: []))
    }
    struct AnalyticsPayload: Content {
        var totalMembers: Int; var totalPosts: Int
        var memberGrowthRate: Double; var postGrowthRate: Double
        var dailySnapshots: [String]; var topPosts: [String]
    }
}

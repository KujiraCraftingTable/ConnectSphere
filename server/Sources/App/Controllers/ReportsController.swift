import Vapor
import SQLKit

/// Port of `backend/src/services/reportService.js` + `reportController.js` +
/// `reportModel.js`. `clientError` → `Abort` ({status,code,message}).
/// The staff auto-notify on threshold is deferred with the rest of the
/// notification fan-out; the folded review fix (`>= 5 && < 10` window instead
/// of a bare `=== 5`) is carried in the comment for when it's wired.
struct ReportsController {
    static let validReasons = ["spam", "harassment", "hate_speech", "misinformation", "off_topic", "other"]
    static let autoNotifyThreshold = 5

    /// Community-scoped routes (mounted by CommunitiesController).
    static func registerCommunityRoutes(on c: any RoutesBuilder) {
        c.post(":id", "members", ":userId", "report", use: reportMember)
        c.get(":id", "moderation", use: moderationQueue)
        c.patch(":id", "reports", ":reportId", use: resolveReport)
        c.get(":id", "analytics", use: analytics)
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
        if targetType == "member" && targetID == reporterID { throw Abort(.badRequest, reason: "You cannot report yourself") }

        struct I: Decodable { let id: String }
        if try await db.raw("SELECT id FROM community_reports WHERE reporter_id = \(uuid: reporterID) AND target_type = \(bind: targetType) AND target_id = \(uuid: targetID)")
            .first(decoding: I.self) != nil {
            throw Abort(.conflict, reason: "You have already reported this")
        }
        if targetType == "post" {
            guard let meta = try await PostStore.findMeta(targetID, on: db), meta.community_id == communityID else {
                throw Abort(.notFound, reason: "Post not found in this community")
            }
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
        // TODO(notify): if communityID and pending count in [5,10) → fanOut new_report to admin/mod
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

    // MARK: moderation queue

    struct QueueItem: Content {
        var id: String
        var target_type: String
        var target_id: String
        var reason: String
        @NullCoded var detail: String?
        var status: String
        var created_at: Date
        @NullCoded var post_content: String?
        @NullCoded var member_info: MemberInfo?
        struct MemberInfo: Content {
            var id: String; var username: String; var display_name: String
            @NullCoded var avatar_color: String?
        }
    }
    struct QueueResult: Content { var reports: [QueueItem]; var pendingCount: Int }

    static func moderationQueue(_ req: Request) async throws -> DataResponse<QueueResult> {
        let id = req.parameters.get("id")!
        let db = req.db.sql()
        guard CommunitiesController.staff(try await CommunityStore.membership(id, req.userID, on: db)) else {
            throw Abort(.forbidden, reason: "Only admins and moderators can access the moderation queue")
        }
        let status = (try? req.query.get(String.self, at: "status")) ?? "pending"
        let limit = (try? req.query.get(Int.self, at: "limit")) ?? 20
        let offset = (try? req.query.get(Int.self, at: "offset")) ?? 0

        var q: SQLQueryString = """
            SELECT r.id::text AS id, r.target_type, r.target_id::text AS target_id, r.reason, r.detail, r.status, r.created_at,
              CASE WHEN r.target_type = 'post' THEN (SELECT p.content FROM posts p WHERE p.id = r.target_id) ELSE NULL END AS post_content,
              CASE WHEN r.target_type = 'member' THEN json_build_object('id', u.id, 'username', u.username,
                'display_name', u.display_name, 'avatar_color', u.avatar_color) ELSE NULL END::text AS member_info
            FROM community_reports r
            LEFT JOIN users u ON u.id = r.target_id AND r.target_type = 'member'
            WHERE r.community_id = \(uuid: id)
            """
        if status == "resolved" { q = q + " AND r.status IN ('resolved', 'dismissed')" }
        else if status != "all" { q = q + " AND r.status = \(bind: status)" }
        q = q + " ORDER BY r.created_at DESC LIMIT \(bind: limit) OFFSET \(bind: offset)"

        struct Row: Decodable {
            let id: String; let target_type: String; let target_id: String; let reason: String; let detail: String?
            let status: String; let created_at: Date; let post_content: String?; let member_info: String?
        }
        let rows = try await db.raw(q).all(decoding: Row.self)
        let dec = JSONCoding.makeDecoder()
        let items = try rows.map { r -> QueueItem in
            QueueItem(id: r.id, target_type: r.target_type, target_id: r.target_id, reason: r.reason, detail: r.detail,
                      status: r.status, created_at: r.created_at, post_content: r.post_content,
                      member_info: (r.member_info != nil && r.member_info != "null") ? try dec.decode(QueueItem.MemberInfo.self, from: Data(r.member_info!.utf8)) : nil)
        }
        struct N: Decodable { let n: Int }
        let pending = try await db.raw("SELECT COUNT(*)::int AS n FROM community_reports WHERE community_id = \(uuid: id) AND status = 'pending'")
            .first(decoding: N.self)!.n
        return DataResponse(data: QueueResult(reports: items, pendingCount: pending))
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
        struct RR: Decodable { let id: String; let community_id: String?; let status: String; let target_type: String; let target_id: String }
        guard let report = try await db.raw("SELECT id::text AS id, community_id::text AS community_id, status, target_type, target_id::text AS target_id FROM community_reports WHERE id = \(uuid: reportID)")
            .first(decoding: RR.self) else { throw Abort(.notFound, reason: "Report not found") }
        if report.status != "pending" { throw Abort(.conflict, reason: "Report has already been reviewed") }
        guard let cid = report.community_id else { throw Abort(.badRequest, reason: "Report has no community") }
        let reviewerRole = try await CommunityStore.membership(cid, req.userID, on: db)
        guard CommunitiesController.staff(reviewerRole) else {
            throw Abort(.forbidden, reason: "Only admins and moderators can resolve reports")
        }
        if action == "remove_content" && report.target_type != "post" {
            throw Abort(.badRequest, reason: "remove_content is only valid for post reports")
        }
        if action == "ban_member" && report.target_type != "member" {
            throw Abort(.badRequest, reason: "ban_member is only valid for member reports")
        }

        if action == "remove_content" {
            if let deleted = try await PostStore.softDelete(report.target_id, on: db), let dcid = deleted.community_id {
                try await CommunityStore.incrementPostCount(dcid, -1, on: db)
            }
            // TODO(notify): content_removed
        } else if action == "ban_member" {
            let target = try await CommunityStore.membership(cid, report.target_id, on: db)
            if target == "admin" && reviewerRole != "admin" {
                throw Abort(.forbidden, reason: "Only admins can ban other admins")
            }
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
        let finalStatus = action == "dismiss" ? "dismissed" : "resolved"
        let updated = try await db.raw("""
            UPDATE community_reports SET status = \(bind: finalStatus), resolved_by = \(uuid: req.userID), resolved_at = NOW()
            WHERE id = \(uuid: reportID)
            RETURNING id::text AS id, reporter_id::text AS reporter_id, target_type, target_id::text AS target_id,
              community_id::text AS community_id, reason, detail, status, resolved_by::text AS resolved_by, resolved_at, created_at
            """).first(decoding: ReportRow.self)!
        return DataResponse(data: updated)
    }

    // MARK: analytics — deferred to Phase 3 tail (analyticsService)

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

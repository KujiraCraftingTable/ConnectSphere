import Vapor
import SQLKit

/// The notification inbox (read side) and the notification type table. Mounted at
/// both `/api/notifications` and `/api/user-notifications`; every mutation
/// accepts PATCH and POST.
///
/// The notification *creation* / fan-out side (pushUserNotification,
/// createBulkForCommunity, upsertMessageNotification) is deferred, it's all
/// fire-and-forget from other handlers and doesn't shape any response. The
/// read/mark/delete/resolve inbox is fully ported here.
struct NotificationsController {
    static let defaultLimit = 30
    static let maxLimit = 100
    static let categories = ["social", "community", "chat"]

    struct TypeSpec { let category: String; let destination: String }
    static let types: [String: TypeSpec] = [
        "post_liked":          .init(category: "social", destination: "post"),
        "post_commented":      .init(category: "social", destination: "post"),
        "comment_replied":     .init(category: "social", destination: "post"),
        "comment_liked":       .init(category: "social", destination: "post"),
        "post_shared":         .init(category: "social", destination: "post"),
        "connection_request":  .init(category: "social", destination: "profile"),
        "connection_accepted": .init(category: "social", destination: "profile"),
        "birthday":            .init(category: "social", destination: "profile"),
        "mode_mismatch":       .init(category: "social", destination: "none"),
        "skill_endorsed":      .init(category: "social", destination: "profile"),
        "new_login":           .init(category: "social", destination: "none"),
        "job_application":     .init(category: "social", destination: "jobApplicants"),
        "application_status":  .init(category: "social", destination: "job"),
        "scheduled_post_live": .init(category: "social", destination: "post"),
        "message":             .init(category: "chat", destination: "conversation"),
        "meeting_proposed":    .init(category: "chat", destination: "conversation"),
        "meeting_updated":     .init(category: "chat", destination: "conversation"),
        "meeting_rsvp":        .init(category: "chat", destination: "conversation"),
        "meeting_reminder":    .init(category: "chat", destination: "conversation"),
        "message_reaction":    .init(category: "chat", destination: "conversation"),
        "group_added":         .init(category: "chat", destination: "conversation"),
        "group_removed":       .init(category: "chat", destination: "conversations"),
        "new_post":            .init(category: "community", destination: "communityPost"),
        "pinned_post":         .init(category: "community", destination: "communityPost"),
        "post_approved":       .init(category: "community", destination: "communityPost"),
        "post_declined":       .init(category: "community", destination: "community"),
        "join_request":        .init(category: "community", destination: "communityJoinRequests"),
        "join_approved":       .init(category: "community", destination: "community"),
        "join_rejected":       .init(category: "community", destination: "community"),
        "role_changed":        .init(category: "community", destination: "community"),
        "new_report":          .init(category: "community", destination: "communityReports"),
        "content_removed":     .init(category: "community", destination: "community"),
    ]

    static func typesForCategory(_ cat: String?) -> [String]? {
        guard let cat, cat != "all", categories.contains(cat) else { return nil }
        return types.filter { $0.value.category == cat }.map(\.key)
    }

    /// Chat activity that's already reflected by the Messages tab's own
    /// unread badge, redundant to also surface in the Notifications inbox.
    /// Meeting types ("meeting_proposed"/"meeting_updated"/"meeting_rsvp"/
    /// "meeting_reminder") are deliberately NOT included here even though
    /// they're also `category: "chat"`, those are calendar-like reminders,
    /// not "someone messaged me," and stay in the inbox per explicit product
    /// direction ("keep the reminder for calendar and similar features").
    static let excludedFromInbox: [String] = ["message", "message_reaction", "group_added", "group_removed"]

    static func register(routes: any RoutesBuilder) {
        for prefix in ["notifications", "user-notifications"] {
            let n = routes.grouped(PathComponent(stringLiteral: prefix)).grouped(AuthMiddleware())
            n.get(use: list)
            n.get("unread-count", use: unreadCount)
            n.get("communities", use: listCommunityShim)
            for verb in [HTTPMethod.PATCH, .POST] {
                n.on(verb, "read-all", use: markAllRead)
                n.on(verb, ":id", "read", use: markRead)
                n.on(verb, ":id", "unread", use: markUnread)
            }
            n.post(":id", "resolve", use: resolve)
            n.delete(":id", use: remove)
        }
    }

    // MARK: DTO shaping

    struct Row: Decodable {
        var id: String; var user_id: String; var type: String
        var actor_id: String?; var post_id: String?; var community_id: String?
        var conversation_id: String?; var entity_type: String?; var entity_id: String?
        var group_key: String; var payload: String   // ::text
        var collapse_count: Int; var is_read: Bool; var resolved_at: Date?
        var created_at: Date; var updated_at: Date; var community_name: String?
    }

    static let selectColumns: SQLQueryString = """
        n.id::text AS id, n.user_id::text AS user_id, n.type, n.actor_id::text AS actor_id,
        n.post_id::text AS post_id, n.community_id::text AS community_id, n.conversation_id::text AS conversation_id,
        n.entity_type, n.entity_id::text AS entity_id,
        COALESCE(n.group_key, n.type || ':' || n.id::text) AS group_key,
        n.payload::text AS payload, n.collapse_count, n.is_read, n.resolved_at,
        n.created_at, n.updated_at, c.name AS community_name
        """

    /// Build `{ ...row, group_key, category, destination }` as raw JSON bytes.
    static func toDTOJSON(_ r: Row) -> Data {
        func js(_ s: String) -> String { String(data: (try? JSONEncoder().encode(s)) ?? Data("\"\"".utf8), encoding: .utf8) ?? "\"\"" }
        func jsOpt(_ s: String?) -> String { s.map(js) ?? "null" }
        func ts(_ d: Date) -> String { js(JSONCoding.isoFractional.string(from: d)) }
        let category = types[r.type]?.category
        let dest = destination(r)
        var out = "{"
        out += "\"id\":\(js(r.id)),\"user_id\":\(js(r.user_id)),\"type\":\(js(r.type)),"
        out += "\"actor_id\":\(jsOpt(r.actor_id)),\"post_id\":\(jsOpt(r.post_id)),\"community_id\":\(jsOpt(r.community_id)),"
        out += "\"conversation_id\":\(jsOpt(r.conversation_id)),\"entity_type\":\(jsOpt(r.entity_type)),\"entity_id\":\(jsOpt(r.entity_id)),"
        out += "\"group_key\":\(js(r.group_key)),\"payload\":\(r.payload == "null" ? "{}" : r.payload),"
        out += "\"collapse_count\":\(r.collapse_count),\"is_read\":\(r.is_read),"
        out += "\"resolved_at\":\(r.resolved_at.map(ts) ?? "null"),"
        out += "\"created_at\":\(ts(r.created_at)),\"updated_at\":\(ts(r.updated_at)),"
        out += "\"community_name\":\(jsOpt(r.community_name)),"
        out += "\"category\":\(jsOpt(category)),\"destination\":\(dest)}"
        return Data(out.utf8)
    }

    static func destination(_ r: Row) -> String {
        let kind = types[r.type]?.destination ?? "none"
        func j(_ s: String?) -> String { s.map { "\"\($0)\"" } ?? "null" }
        // payload lookups
        let p = (try? JSONSerialization.jsonObject(with: Data(r.payload.utf8))) as? [String: Any] ?? [:]
        func ps(_ k: String) -> String? { p[k] as? String }
        switch kind {
        case "post": return "{\"kind\":\"post\",\"postId\":\(j(r.post_id ?? ps("postId"))),\"commentId\":\(j(ps("commentId")))}"
        case "profile": return "{\"kind\":\"profile\",\"userId\":\(j(r.actor_id ?? ps("fromUserId")))}"
        case "conversation": return "{\"kind\":\"conversation\",\"conversationId\":\(j(r.conversation_id ?? ps("conversationId"))),\"messageId\":\(j(ps("messageId")))}"
        case "conversations": return "{\"kind\":\"conversations\"}"
        case "job", "jobApplicants": return "{\"kind\":\"\(kind)\",\"jobId\":\(j(ps("jobId")))}"
        case "communityPost": return "{\"kind\":\"communityPost\",\"communityId\":\(j(r.community_id)),\"postId\":\(j(r.post_id ?? ps("refId")))}"
        case "communityJoinRequests", "communityReports", "community":
            return "{\"kind\":\"\(kind)\",\"communityId\":\(j(r.community_id))}"
        default: return "{\"kind\":\"none\"}"
        }
    }

    // MARK: cursor

    static func decodeCursor(_ c: String?) -> (updatedAt: String, id: String)? {
        guard let c, let data = Data(base64Encoded: c), let s = String(data: data, encoding: .utf8) else { return nil }
        let parts = s.split(separator: "|", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        return (String(parts[0]), String(parts[1]))
    }
    static func encodeCursor(_ r: Row) -> String {
        Data("\(JSONCoding.isoFractional.string(from: r.updated_at))|\(r.id)".utf8).base64EncodedString()
    }

    // MARK: GET /

    static func list(_ req: Request) async throws -> Response {
        let limit = min((try? req.query.get(Int.self, at: "limit")) ?? defaultLimit, maxLimit)
        let offset = (try? req.query.get(Int.self, at: "offset")) ?? 0
        let unreadOnly = (try? req.query.get(String.self, at: "filter")) == "unread"
        let cat = try? req.query.get(String.self, at: "category")
        let typeList = typesForCategory(cat)
        let cursor = decodeCursor(try? req.query.get(String.self, at: "cursor"))
        let mode = requestedMode(req)
        let db = req.db.sql()

        var q: SQLQueryString = "SELECT " + selectColumns + """
             FROM user_notifications n LEFT JOIN communities c ON c.id = n.community_id
            WHERE n.user_id = \(uuid: req.userID) AND NOT (n.type = ANY(\(bind: excludedFromInbox)::text[]))
            AND
            """ + visibleIn(mode)
        if unreadOnly { q = q + " AND n.is_read = FALSE" }
        if let typeList { q = q + " AND n.type = ANY(\(bind: typeList)::text[])" }
        if let cursor {
            q = q + " AND (n.updated_at, n.id) < (\(bind: cursor.updatedAt)::timestamptz, \(uuid: cursor.id))"
        }
        q = q + " ORDER BY n.updated_at DESC, n.id DESC LIMIT \(bind: limit + 1) OFFSET \(bind: cursor == nil ? offset : 0)"
        let rows = try await db.raw(q).all(decoding: Row.self)
        let hasMore = rows.count > limit
        let page = hasMore ? Array(rows.prefix(limit)) : rows

        let (unread, byCat) = try await summary(req.userID, mode: mode, on: db)

        var body = Data(#"{"data":["#.utf8)
        for (i, r) in page.enumerated() { if i > 0 { body.append(Data(",".utf8)) }; body.append(toDTOJSON(r)) }
        body.append(Data("],\"unread\":\(unread),\"counts\":{\"total\":\(unread),\"social\":\(byCat["social"]!),\"community\":\(byCat["community"]!),\"chat\":\(byCat["chat"]!)},\"hasMore\":\(hasMore),\"nextCursor\":".utf8))
        let cursorFragment = (hasMore && !page.isEmpty) ? "\"\(encodeCursor(page.last!))\"" : "null"
        body.append(Data(cursorFragment.utf8))
        body.append(Data("}".utf8))
        return Response(status: .ok, headers: ["content-type": "application/json; charset=utf-8"], body: .init(data: body))
    }

    /// The mode a request is for (`?mode=hobby|work`); nil = every mode.
    static func requestedMode(_ req: Request) -> String? {
        guard let mode = try? req.query.get(String.self, at: "mode"), ["hobby", "work"].contains(mode) else { return nil }
        return mode
    }

    /// Hobby and Work are two separate lives, so a notification shows only in
    /// the mode it was raised in: a post's (or chat's, or community's) own
    /// mode, the mode a connection is in, Work for endorsements and jobs.
    /// A sign-in alert, or anything that can't be placed,
    /// shows in both. Expects the table aliased `n`; `mode` is allowlisted by
    /// `requestedMode`, so it's safe to bind and compare.
    static func visibleIn(_ mode: String?) -> SQLQueryString {
        // Parenthesised: callers glue this straight onto "... AND", and a bare
        // TRUE became "ANDTRUE", a syntax error on every call without a mode.
        guard let mode else { return "(TRUE)" }
        return """
            (CASE n.type
               WHEN 'new_login' THEN TRUE
               WHEN 'skill_endorsed' THEN \(bind: mode) = 'work'
               WHEN 'job_application' THEN \(bind: mode) = 'work'
               WHEN 'application_status' THEN \(bind: mode) = 'work'
               WHEN 'connection_request' THEN EXISTS (\(connectionIn(mode)))
               WHEN 'connection_accepted' THEN EXISTS (\(connectionIn(mode)))
               WHEN 'birthday' THEN EXISTS (\(connectionIn(mode)))
               ELSE COALESCE(
                 (SELECT p.mode FROM posts p WHERE p.id = n.post_id),
                 (SELECT cv.mode FROM conversations cv WHERE cv.id = n.conversation_id),
                 (SELECT CASE WHEN cm.type = 'work' THEN 'work' ELSE 'hobby' END FROM communities cm WHERE cm.id = n.community_id),
                 \(bind: mode)) = \(bind: mode)
             END)
            """
    }

    /// A connection between the notification's two people in `mode`.
    private static func connectionIn(_ mode: String) -> SQLQueryString {
        """
        SELECT 1 FROM connections cn WHERE cn.mode = \(bind: mode)
          AND ((cn.requester_id = n.actor_id AND cn.addressee_id = n.user_id)
            OR (cn.requester_id = n.user_id AND cn.addressee_id = n.actor_id))
        """
    }

    static func summary(_ userID: String, mode: String? = nil, on db: any SQLDatabase) async throws -> (Int, [String: Int]) {
        struct C: Decodable { let type: String; let count: Int }
        let rows = try await db.raw("""
            SELECT n.type, COUNT(*)::int AS count FROM user_notifications n
            WHERE n.user_id = \(uuid: userID) AND n.is_read = FALSE AND NOT (n.type = ANY(\(bind: excludedFromInbox)::text[]))
            AND
            """ + visibleIn(mode) + " GROUP BY n.type")
            .all(decoding: C.self)
        var byCat = ["social": 0, "community": 0, "chat": 0]
        var unread = 0
        for r in rows {
            unread += r.count
            if let cat = types[r.type]?.category { byCat[cat, default: 0] += r.count }
        }
        return (unread, byCat)
    }

    // MARK: GET /unread-count

    struct UnreadResp: Content { var data: Inner; struct Inner: Content { var count: Int; var byCategory: [String: Int] } }
    static func unreadCount(_ req: Request) async throws -> UnreadResp {
        let (unread, byCat) = try await summary(req.userID, mode: requestedMode(req), on: req.db.sql())
        let scope = try? req.query.get(String.self, at: "scope")
        let count = (scope.flatMap { categories.contains($0) ? byCat[$0] : nil }) ?? unread
        return UnreadResp(data: .init(count: count, byCategory: byCat))
    }

    // MARK: mutations

    struct StatusUnread: Content { var status = "ok"; var data: Inner; struct Inner: Content { var unread: Int } }
    struct StatusOnly: Content { var status = "ok" }
    struct StatusMsg: Content { var status = "ok"; var message: String }

    static func setRead(_ req: Request, _ isRead: Bool) async throws -> StatusUnread {
        let db = req.db.sql()
        let nid = req.parameters.get("id")!
        struct R: Decodable { let id: String }
        guard try await db.raw("UPDATE user_notifications SET is_read = \(bind: isRead) WHERE id = \(uuid: nid) AND user_id = \(uuid: req.userID) RETURNING id")
            .first(decoding: R.self) != nil else { throw Abort(.notFound, reason: "Notification not found") }
        req.socketHub.emitToUser(req.userID, event: "notification_read", NotifyService.ReadPayload(ids: [nid], isRead: isRead))
        await NotifyService.emitCounts(req.userID, on: db, hub: req.socketHub)
        return StatusUnread(data: .init(unread: try await summary(req.userID, mode: requestedMode(req), on: db).0))
    }
    static func markRead(_ req: Request) async throws -> StatusUnread { try await setRead(req, true) }
    static func markUnread(_ req: Request) async throws -> StatusUnread { try await setRead(req, false) }

    static func markAllRead(_ req: Request) async throws -> StatusUnread {
        let db = req.db.sql()
        let typeList = typesForCategory(try? req.query.get(String.self, at: "category"))
        let mode = requestedMode(req)
        // Only this mode's: reading everything in Hobby must not clear Work's.
        var q: SQLQueryString = """
            UPDATE user_notifications n SET is_read = TRUE
            WHERE n.user_id = \(uuid: req.userID) AND n.is_read = FALSE AND
            """ + visibleIn(mode)
        if let typeList { q = q + " AND n.type = ANY(\(bind: typeList)::text[])" }
        try await db.raw(q).run()
        return StatusUnread(data: .init(unread: try await summary(req.userID, mode: mode, on: db).0))
    }

    static func remove(_ req: Request) async throws -> StatusUnread {
        let db = req.db.sql()
        struct R: Decodable { let id: String }
        let deleted = try await db.raw("DELETE FROM user_notifications WHERE id = \(uuid: req.parameters.get("id")!) AND user_id = \(uuid: req.userID) RETURNING id")
            .all(decoding: R.self)
        guard !deleted.isEmpty else { throw Abort(.notFound, reason: "Notification not found") }
        return StatusUnread(data: .init(unread: try await summary(req.userID, mode: requestedMode(req), on: db).0))
    }

    struct ResolveBody: Content { var action: String? }
    static func resolve(_ req: Request) async throws -> Response {
        let db = req.db.sql()
        guard let action = try req.content.decode(ResolveBody.self).action, ["keep", "switch"].contains(action) else {
            throw Abort(.badRequest, reason: "action must be keep or switch")
        }
        struct N: Decodable { let user_id: String; let post_id: String?; let payload: String; let resolved_at: Date? }
        guard let n = try await db.raw("SELECT user_id::text AS user_id, post_id::text AS post_id, payload::text AS payload, resolved_at FROM user_notifications WHERE id = \(uuid: req.parameters.get("id")!)")
            .first(decoding: N.self), n.user_id == req.userID else { throw Abort(.notFound, reason: "Notification not found") }
        if n.resolved_at != nil {
            return try await ConnectionsController.encode(StatusMsg(message: "Already resolved"), req, .ok)
        }
        if action == "switch", let postID = n.post_id,
           let p = (try? JSONSerialization.jsonObject(with: Data(n.payload.utf8))) as? [String: Any],
           let suggested = p["suggestedMode"] as? String {
            try await db.raw("UPDATE posts SET mode = \(bind: suggested) WHERE id = \(uuid: postID) AND status = 'posted'").run()
        }
        try await db.raw("UPDATE user_notifications SET is_read = TRUE, resolved_at = NOW() WHERE id = \(uuid: req.parameters.get("id")!) AND user_id = \(uuid: req.userID)").run()
        return try await ConnectionsController.encode(StatusOnly(), req, .ok)
    }

    // MARK: GET /communities (deprecated shim)

    struct CommShimRow: Content {
        var id: String; @NullCoded var community_id: String?; var type: String
        @NullCoded var ref_id: String?; var is_read: Bool; var created_at: Date; @NullCoded var community_name: String?
    }
    static func listCommunityShim(_ req: Request) async throws -> DataListResponse<CommShimRow> {
        let limit = min((try? req.query.get(Int.self, at: "limit")) ?? 20, maxLimit)
        let offset = (try? req.query.get(Int.self, at: "offset")) ?? 0
        let commTypes = typesForCategory("community")!
        let rows = try await req.db.sql().raw("""
            SELECT n.id::text AS id, n.community_id::text AS community_id, n.type,
              COALESCE(n.entity_id, n.post_id)::text AS ref_id, n.is_read, n.created_at, c.name AS community_name
            FROM user_notifications n LEFT JOIN communities c ON c.id = n.community_id
            WHERE n.user_id = \(uuid: req.userID) AND n.type = ANY(\(bind: commTypes)::text[])
            ORDER BY n.updated_at DESC, n.id DESC LIMIT \(bind: limit) OFFSET \(bind: offset)
            """).all(decoding: CommShimRow.self)
        return DataListResponse(data: rows)
    }
}

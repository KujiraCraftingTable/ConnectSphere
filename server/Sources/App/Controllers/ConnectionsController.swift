import Vapor
import SQLKit

/// Inline `{error}` bodies. `/request` maps a unique-violation to 409 instead of a 500.
struct ConnectionsController {
    static func register(routes: any RoutesBuilder) {
        let c = routes.grouped("connections").grouped(AuthMiddleware())
        c.get(use: list)
        c.get("status", ":targetId", use: status)
        c.post("request", use: request)
        c.post("accept", use: accept)
        c.post("decline", use: decline)
        c.post("cancel", use: cancel)
        c.post("remove", use: remove)
    }

    struct Conn: Decodable {
        var id: String
        var requester_id: String
        var addressee_id: String
        var status: String
    }

    static func findConnection(_ a: String, _ b: String, mode: String, on db: any SQLDatabase) async throws -> Conn? {
        try await db.raw("""
            SELECT id::text AS id, requester_id::text AS requester_id, addressee_id::text AS addressee_id, status
            FROM connections
            WHERE mode = \(bind: mode)
              AND ((requester_id = \(uuid: a) AND addressee_id = \(uuid: b))
                OR (requester_id = \(uuid: b) AND addressee_id = \(uuid: a)))
            ORDER BY updated_at DESC LIMIT 1
            """).first(decoding: Conn.self)
    }

    // MARK: GET /api/connections

    struct ConnItem: Content {
        var connection_id: String
        var status: String
        var mode: String
        var updated_at: Date
        var user: ConnUser
        struct ConnUser: Content {
            var id: String
            var username: String
            var display_name: String
            @NullCoded var avatar_color: String?
            @NullCoded var avatar_url: String?
            @NullCoded var job_title: String?
            @NullCoded var company: String?
            @NullCoded var location: String?
        }
    }

    static func list(_ req: Request) async throws -> DataListResponse<ConnItem> {
        let mode = ["hobby", "work"].contains((try? req.query.get(String.self, at: "mode")) ?? "") ? (try! req.query.get(String.self, at: "mode")) : "hobby"
        let statusQ = (try? req.query.get(String.self, at: "status")) ?? "accepted"
        let status = ["accepted", "pending_received", "pending_sent"].contains(statusQ) ? statusQ : "accepted"
        let clause: SQLQueryString
        switch status {
        case "pending_received": clause = "c.status = 'pending' AND c.addressee_id = \(uuid: req.userID)"
        case "pending_sent": clause = "c.status = 'pending' AND c.requester_id = \(uuid: req.userID)"
        default: clause = "c.status = 'accepted' AND (c.requester_id = \(uuid: req.userID) OR c.addressee_id = \(uuid: req.userID))"
        }
        struct Row: Decodable { let connection_id: String; let status: String; let mode: String; let updated_at: Date; let user: String }
        let rows = try await req.db.sql().raw("""
            SELECT c.id::text AS connection_id, c.status, c.mode, c.updated_at,
              json_build_object('id', u.id, 'username', u.username,
                'display_name', \(unsafeRaw: PersonaSQL.expr("display_name", modeRef: "c.mode")),
                'avatar_color', u.avatar_color, 'avatar_url', \(unsafeRaw: PersonaSQL.expr("avatar_url", modeRef: "c.mode")),
                'job_title', u.job_title, 'company', u.company, 'location', u.location)::text AS user
            FROM connections c
            JOIN users u ON u.id = CASE WHEN c.requester_id = \(uuid: req.userID) THEN c.addressee_id ELSE c.requester_id END
            WHERE c.mode = \(bind: mode) AND \(clause)
            ORDER BY c.updated_at DESC
            """).all(decoding: Row.self)
        let dec = JSONCoding.makeDecoder()
        return DataListResponse(data: try rows.map {
            ConnItem(connection_id: $0.connection_id, status: $0.status, mode: $0.mode, updated_at: $0.updated_at,
                     user: try dec.decode(ConnItem.ConnUser.self, from: Data($0.user.utf8)))
        })
    }

    // MARK: GET /api/connections/status/:targetId

    struct StatusResponse: Content {
        var status: String
        @NullCoded var connection_id: String?
        /// Whether the viewer follows the target in this mode (independent of friendship).
        var is_following = false
        /// False when the target turned friend requests off. The app offers Follow instead.
        var accepts_requests = true
    }

    static func status(_ req: Request) async throws -> StatusResponse {
        let targetID = req.parameters.get("targetId")!
        let mode = ["hobby", "work"].contains((try? req.query.get(String.self, at: "mode")) ?? "") ? (try! req.query.get(String.self, at: "mode")) : "hobby"
        if req.userID == targetID { return StatusResponse(status: "self", connection_id: nil) }
        let db = req.db.sql()
        async let following = FollowStore.isFollowing(req.userID, targetID, mode: mode, on: db)
        async let accepts = acceptsRequests(targetID, on: db)
        guard let conn = try await findConnection(req.userID, targetID, mode: mode, on: db) else {
            return StatusResponse(status: "none", connection_id: nil,
                                  is_following: try await following, accepts_requests: try await accepts)
        }
        let s: String
        if conn.status == "accepted" { s = "accepted" }
        else if conn.status == "pending" { s = conn.requester_id == req.userID ? "pending_sent" : "pending_received" }
        else { s = conn.status }
        return StatusResponse(status: s, connection_id: conn.id,
                              is_following: try await following, accepts_requests: try await accepts)
    }

    static func acceptsRequests(_ userID: String, on db: any SQLDatabase) async throws -> Bool {
        struct A: Decodable { let allow_friend_requests: Bool }
        return try await db.raw("SELECT allow_friend_requests FROM users WHERE id = \(uuid: userID)")
            .first(decoding: A.self)?.allow_friend_requests ?? true
    }

    // MARK: POST /api/connections/request

    struct RequestBody: Content { var addressee_id: String?; var mode: String? }
    struct ConnResult: Content { var connection_id: String; var status: String }

    static func request(_ req: Request) async throws -> Response {
        let b = try req.content.decode(RequestBody.self)
        let mode = b.mode ?? "hobby"
        guard let addresseeID = b.addressee_id else { throw InlineError(.badRequest, "addressee_id required") }
        guard ["hobby", "work"].contains(mode) else { throw InlineError(.badRequest, "Invalid mode") }
        guard req.userID.caseInsensitiveCompare(addresseeID) != .orderedSame else { throw InlineError(.badRequest, "Cannot connect with yourself") }
        let db = req.db.sql()
        struct I: Decodable { let id: String }
        guard try await UserStore.isActive(addresseeID, on: db) else {
            throw InlineError(.notFound, "User not found")
        }
        struct One: Decodable { let one: Int }
        if try await db.raw("""
            SELECT 1 AS one FROM user_blocks
            WHERE (blocker_id = \(uuid: req.userID) AND blocked_id = \(uuid: addresseeID))
               OR (blocker_id = \(uuid: addresseeID) AND blocked_id = \(uuid: req.userID))
            """).first(decoding: One.self) != nil {
            throw InlineError(.forbidden, "Cannot send request to this user")
        }
        let existingConnection = try await findConnection(req.userID, addresseeID, mode: mode, on: db)
        // Turned off → strangers can only follow. A request they already
        // sent us can still be answered (that's handled as "pending_received").
        if existingConnection == nil || existingConnection?.status == "rejected",
           !(try await acceptsRequests(addresseeID, on: db)) {
            throw InlineError(.forbidden, "This person isn't accepting friend requests")
        }
        // Adding a friend includes following them (they may unfollow later
        // and stay friends).
        try await FollowStore.follow(req.userID, addresseeID, mode: mode, on: db)
        if let existing = existingConnection {
            switch existing.status {
            case "accepted":
                return try await encode(ConnResult(connection_id: existing.id, status: "accepted"), req, .ok)
            case "pending":
                let s = existing.requester_id == req.userID ? "pending_sent" : "pending_received"
                return try await encode(ConnResult(connection_id: existing.id, status: s), req, .ok)
            case "blocked":
                throw InlineError(.forbidden, "Cannot send request to this user")
            case "rejected":
                let updated = try await db.raw("""
                    UPDATE connections SET requester_id = \(uuid: req.userID), addressee_id = \(uuid: addresseeID),
                      status = 'pending', updated_at = NOW()
                    WHERE id = \(uuid: existing.id) RETURNING id::text AS id
                    """).first(decoding: I.self)!
                NotifyService.dispatchSocial(req, .init(
                    type: "connection_request", actorID: req.userID, recipientID: addresseeID,
                    connectionID: updated.id))
                SearchController.creditOutcome(req, to: addresseeID, column: "connected_at")
                return try await encode(ConnResult(connection_id: updated.id, status: "pending_sent"), req, .created)
            default: break
            }
        }
        do {
            let created = try await db.raw("""
                INSERT INTO connections (requester_id, addressee_id, mode)
                VALUES (\(uuid: req.userID), \(uuid: addresseeID), \(bind: mode))
                RETURNING id::text AS id
                """).first(decoding: I.self)!
            NotifyService.dispatchSocial(req, .init(
                type: "connection_request", actorID: req.userID, recipientID: addresseeID,
                connectionID: created.id))
            SearchController.creditOutcome(req, to: addresseeID, column: "connected_at")
            return try await encode(ConnResult(connection_id: created.id, status: "pending_sent"), req, .created)
        } catch {
            // Folded review fix: concurrent duplicate insert → 409, not an
            // uncaught 23505 → 500. Re-resolve and return the existing row.
            if PGError.isUniqueViolation(error), let now = try await findConnection(req.userID, addresseeID, mode: mode, on: db) {
                let s = now.status == "accepted" ? "accepted"
                    : (now.requester_id == req.userID ? "pending_sent" : "pending_received")
                return try await encode(ConnResult(connection_id: now.id, status: s), req, .ok)
            }
            throw error
        }
    }

    static func encode<T: Content>(_ v: T, _ req: Request, _ status: HTTPResponseStatus) async throws -> Response {
        let res = try await v.encodeResponse(for: req)
        res.status = status
        return res
    }

    // MARK: accept / decline / cancel / remove

    struct IDBody: Content { var connection_id: String? }
    struct StatusOnly: Content { var status: String }
    struct AcceptResp: Content { var status = "accepted"; var connection_id: String }

    static func accept(_ req: Request) async throws -> AcceptResp {
        guard let cid = try req.content.decode(IDBody.self).connection_id else { throw InlineError(.badRequest, "connection_id required") }
        struct C: Decodable { let id: String; let requester_id: String; let addressee_id: String; let mode: String }
        var conn: C?
        try await req.db.tx { t in
            conn = try await t.raw("""
                UPDATE connections SET status = 'accepted', updated_at = NOW()
                WHERE id = \(uuid: cid) AND addressee_id = \(uuid: req.userID) AND status = 'pending'
                RETURNING id::text AS id, requester_id::text AS requester_id, addressee_id::text AS addressee_id, mode
                """).first(decoding: C.self)
            guard let c = conn else { return }
            try await t.raw("UPDATE users SET follower_count = follower_count + 1, following_count = following_count + 1 WHERE id IN (\(uuid: c.requester_id), \(uuid: c.addressee_id))").run()
            // Friends follow each other from the start.
            try await FollowStore.follow(c.requester_id, c.addressee_id, mode: c.mode, on: t)
            try await FollowStore.follow(c.addressee_id, c.requester_id, mode: c.mode, on: t)
        }
        guard let c = conn else { throw InlineError(.conflict, "Request not found, not yours, or already handled") }
        NotifyService.dispatchSocial(req, .init(
            type: "connection_accepted", actorID: req.userID, recipientID: c.requester_id,
            connectionID: c.id))
        return AcceptResp(connection_id: c.id)
    }

    static func decline(_ req: Request) async throws -> StatusOnly {
        guard let cid = try req.content.decode(IDBody.self).connection_id else { throw InlineError(.badRequest, "connection_id required") }
        struct R: Decodable { let id: String }
        let rows = try await req.db.sql().raw("""
            UPDATE connections SET status = 'rejected', updated_at = NOW()
            WHERE id = \(uuid: cid) AND addressee_id = \(uuid: req.userID) AND status = 'pending' RETURNING id
            """).all(decoding: R.self)
        guard !rows.isEmpty else { throw InlineError(.conflict, "Request not found, not yours, or already handled") }
        return StatusOnly(status: "rejected")
    }

    static func cancel(_ req: Request) async throws -> StatusOnly {
        guard let cid = try req.content.decode(IDBody.self).connection_id else { throw InlineError(.badRequest, "connection_id required") }
        // Node returns {status:"none"} unconditionally; the review "409 on no-op"
        // fix is deferred (would need an iOS change to not surface it).
        try await req.db.sql().raw("DELETE FROM connections WHERE id = \(uuid: cid) AND requester_id = \(uuid: req.userID) AND status = 'pending'").run()
        return StatusOnly(status: "none")
    }

    static func remove(_ req: Request) async throws -> StatusOnly {
        guard let cid = try req.content.decode(IDBody.self).connection_id else { throw InlineError(.badRequest, "connection_id required") }
        struct R: Decodable { let requester_id: String; let addressee_id: String }
        var removed: R?
        try await req.db.tx { t in
            removed = try await t.raw("""
                DELETE FROM connections
                WHERE id = \(uuid: cid) AND status = 'accepted' AND (requester_id = \(uuid: req.userID) OR addressee_id = \(uuid: req.userID))
                RETURNING requester_id::text AS requester_id, addressee_id::text AS addressee_id
                """).first(decoding: R.self)
            guard let r = removed else { return }
            try await t.raw("""
                UPDATE users SET follower_count = GREATEST(follower_count - 1, 0), following_count = GREATEST(following_count - 1, 0)
                WHERE id IN (\(uuid: r.requester_id), \(uuid: r.addressee_id))
                """).run()
        }
        guard removed != nil else { throw InlineError(.conflict, "Connection not found or not yours") }
        return StatusOnly(status: "none")
    }
}

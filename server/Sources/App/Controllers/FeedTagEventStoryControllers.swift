import Vapor
import SQLKit

/// GET /api/feed/recommendations; and
/// POST /api/feed/impressions, what the viewer looked at.
struct FeedController {
    static func register(routes: any RoutesBuilder) {
        let feed = routes.grouped("feed").grouped(AuthMiddleware())
        feed.get("recommendations", use: recommendations)
        feed.post("impressions", use: impressions)
    }

    struct ImpressionsBody: Content {
        var source: String
        var items: [ImpressionStore.Item]
    }

    /// A batch of sightings from the Home or a community feed (up to 100).
    struct ImpressionsResp: Content { var recorded: Int }
    static func impressions(_ req: Request) async throws -> ImpressionsResp {
        let b = try req.content.decode(ImpressionsBody.self)
        guard ImpressionStore.sources.contains(b.source) else {
            throw Abort(.badRequest, reason: "source must be home or community")
        }
        guard b.items.count <= ImpressionStore.maxItems else {
            throw Abort(.badRequest, reason: "Too many impressions in one batch")
        }
        let totals = ImpressionStore.fold(b.items)
        try await ImpressionStore.record(totals, viewer: req.userID, source: b.source, on: req.db.sql())
        return ImpressionsResp(recorded: totals.count)
    }
    struct CursorResp: Content { var data: [FeedPostObject]; @NullCoded var nextCursor: String? }
    static func recommendations(_ req: Request) async throws -> CursorResp {
        guard let mode = try? req.query.get(String.self, at: "mode"), ["hobby", "work"].contains(mode) else {
            throw StatusMessageError(.badRequest, "mode must be hobby or work")
        }
        let limit = min((try? req.query.get(Int.self, at: "limit")) ?? 20, 50)
        let cursor = try? req.query.get(String.self, at: "cursor")
        let (posts, next) = try await FeedStore.getRecommendedFeed(
            userID: req.userID, mode: mode, cursor: cursor, limit: limit, on: req.db.sql())
        return CursorResp(data: posts, nextCursor: next)
    }
}

/// GET /api/tags/{trending,suggest}.
struct TagsController {
    static func register(routes: any RoutesBuilder) {
        let tags = routes.grouped("tags").grouped(AuthMiddleware())
        tags.get("trending", use: trending)
        tags.get("suggest", use: suggest)
    }
    struct TrendingRow: Content { var tag: String; var post_count: Int }
    struct SuggestRow: Content { var tag: String; var usage_count: Int }

    static func trending(_ req: Request) async throws -> DataListResponse<TrendingRow> {
        let limit = min((try? req.query.get(Int.self, at: "limit")) ?? 10, 30)
        let rows = try await req.db.sql().raw("""
            SELECT pt.tag, COUNT(*)::INT AS post_count
            FROM post_tags pt JOIN posts p ON p.id = pt.post_id
            WHERE pt.source = 'user' AND p.status = 'posted' AND p.created_at >= NOW() - INTERVAL '7 days'
            GROUP BY pt.tag ORDER BY post_count DESC, pt.tag LIMIT \(bind: limit)
            """).all(decoding: TrendingRow.self)
        return DataListResponse(data: rows)
    }
    static func suggest(_ req: Request) async throws -> DataListResponse<SuggestRow> {
        let prefix = ((try? req.query.get(String.self, at: "prefix")) ?? "").trimmingCharacters(in: .whitespaces)
        guard !prefix.isEmpty else { throw InlineError(.badRequest, "prefix is required") }
        let limit = min((try? req.query.get(Int.self, at: "limit")) ?? 10, 20)
        let rows = try await req.db.sql().raw("""
            SELECT tag, COUNT(*)::INT AS usage_count FROM post_tags
            WHERE source = 'user' AND tag ILIKE \(bind: prefix) || '%'
            GROUP BY tag ORDER BY usage_count DESC LIMIT \(bind: limit)
            """).all(decoding: SuggestRow.self)
        return DataListResponse(data: rows)
    }
}

/// POST /api/events/:id/rsvp.
struct EventsController {
    static func register(routes: any RoutesBuilder) {
        routes.grouped("events").grouped(AuthMiddleware()).post(":id", "rsvp", use: rsvp)
    }
    struct RsvpBody: Content { var status: String? }
    struct OKMessage: Content { var status = "ok"; var message = "RSVP recorded" }
    static func rsvp(_ req: Request) async throws -> OKMessage {
        let status = try req.content.decode(RsvpBody.self).status
        try await PostService.rsvpEvent(eventID: req.parameters.get("id")!, userID: req.userID, status: status, on: req.db)
        return OKMessage()
    }
}

/// /api/jobs, "I'm interested" toggle for Job/Opportunity posts.
struct JobsController {
    static func register(routes: any RoutesBuilder) {
        routes.grouped("jobs").grouped(AuthMiddleware()).post(":id", "interest", use: interest)
    }
    struct InterestBody: Content { var interested: Bool? }
    struct OKMessage: Content { var status = "ok"; var message = "Interest updated" }
    static func interest(_ req: Request) async throws -> OKMessage {
        guard let interested = try req.content.decode(InterestBody.self).interested else {
            throw InlineError(.badRequest, "interested is required")
        }
        try await PostService.interestInJob(jobID: req.parameters.get("id")!, userID: req.userID, interested: interested, on: req.db)
        return OKMessage()
    }
}

/// /api/stories.
struct StoriesController {
    static func register(routes: any RoutesBuilder) {
        let s = routes.grouped("stories").grouped(AuthMiddleware())
        s.post(use: create)
        s.get(use: list)
        s.post(":id", "view", use: view)
        s.get(":id", "viewers", use: viewers)
        s.delete(":id", use: remove)
    }

    struct StoryRow: Content {
        var id: String; var author_id: String; var image_url: String
        var created_at: Date; var expires_at: Date
    }
    struct StoryFull: Content {
        var id: String; var author_id: String; var image_url: String
        var created_at: Date; var expires_at: Date; var author: Author; var viewed: Bool
        struct Author: Content {
            var id: String; var username: String; var display_name: String
            @NullCoded var avatar_color: String?; @NullCoded var avatar_url: String?
        }
    }
    struct ViewerRow: Content {
        var id: String; var display_name: String
        @NullCoded var avatar_color: String?; @NullCoded var avatar_url: String?; var viewed_at: Date
    }
    struct CreateBody: Content { var image_url: String?; var mode: String? }

    static func create(_ req: Request) async throws -> Response {
        let body = try req.content.decode(CreateBody.self)
        guard let url = MediaPath.storable(body.image_url) else {
            throw InlineError(.badRequest, "image_url is required")
        }
        guard let mode = body.mode, ["hobby", "work"].contains(mode) else {
            throw InlineError(.badRequest, "mode must be hobby or work")
        }
        let row = try await req.db.sql().raw("""
            INSERT INTO stories (author_id, image_url, mode) VALUES (\(uuid: req.userID), \(bind: url), \(bind: mode))
            RETURNING id, author_id, image_url, created_at, expires_at
            """).first(decoding: StoryRow.self)!
        let res = try await DataResponse(data: row).encodeResponse(for: req)
        res.status = .created
        return res
    }

    static func list(_ req: Request) async throws -> DataListResponse<StoryFull> {
        guard let mode = try? req.query.get(String.self, at: "mode"), ["hobby", "work"].contains(mode) else {
            throw InlineError(.badRequest, "mode must be hobby or work")
        }
        struct Row: Decodable {
            let id: String; let author_id: String; let image_url: String
            let created_at: Date; let expires_at: Date; let author: String; let viewed: Bool
        }
        let rows = try await req.db.sql().raw("""
            SELECT s.id, s.author_id, s.image_url, s.created_at, s.expires_at,
              json_build_object('id', u.id, 'username', u.username,
                'display_name', \(unsafeRaw: PersonaSQL.expr("display_name", modeRef: "s.mode")),
                'avatar_color', u.avatar_color, 'avatar_url', \(unsafeRaw: PersonaSQL.expr("avatar_url", modeRef: "s.mode")))::text AS author,
              EXISTS(SELECT 1 FROM story_views sv WHERE sv.story_id = s.id AND sv.viewer_id = \(uuid: req.userID)) AS viewed
            FROM stories s JOIN users u ON u.id = s.author_id
            WHERE s.expires_at > NOW() AND s.mode = \(bind: mode)
              AND (s.author_id = \(uuid: req.userID) OR EXISTS (SELECT 1 FROM connections c WHERE c.status = 'accepted' AND c.mode = \(bind: mode)
                AND ((c.requester_id = s.author_id AND c.addressee_id = \(uuid: req.userID))
                  OR (c.addressee_id = s.author_id AND c.requester_id = \(uuid: req.userID)))))
              AND NOT EXISTS (SELECT 1 FROM user_blocks ub
                WHERE (ub.blocker_id = \(uuid: req.userID) AND ub.blocked_id = s.author_id)
                   OR (ub.blocker_id = s.author_id AND ub.blocked_id = \(uuid: req.userID)))
            ORDER BY (s.author_id = \(uuid: req.userID)) DESC, s.author_id, s.created_at ASC
            """).all(decoding: Row.self)
        let dec = JSONCoding.makeDecoder()
        let out = try rows.map { r -> StoryFull in
            StoryFull(id: r.id, author_id: r.author_id, image_url: r.image_url, created_at: r.created_at,
                      expires_at: r.expires_at,
                      author: try dec.decode(StoryFull.Author.self, from: Data(r.author.utf8)), viewed: r.viewed)
        }
        return DataListResponse(data: out)
    }

    struct StatusOKMsg: Content { var status = "ok" }
    static func view(_ req: Request) async throws -> StatusOKMsg {
        let id = req.parameters.get("id")!
        struct S: Decodable { let id: String }
        guard try await req.db.sql().raw("SELECT id FROM stories WHERE id = \(uuid: id) AND expires_at > NOW()").first(decoding: S.self) != nil else {
            throw InlineError(.notFound, "Story not found")
        }
        try await req.db.sql().raw("INSERT INTO story_views (story_id, viewer_id) VALUES (\(uuid: id), \(uuid: req.userID)) ON CONFLICT DO NOTHING").run()
        return StatusOKMsg()
    }
    static func viewers(_ req: Request) async throws -> DataListResponse<ViewerRow> {
        let id = req.parameters.get("id")!
        struct S: Decodable { let author_id: String; let mode: String }
        guard let s = try await req.db.sql().raw("SELECT author_id, mode FROM stories WHERE id = \(uuid: id)").first(decoding: S.self),
              s.author_id == req.userID else { throw InlineError(.notFound, "Story not found") }
        // Viewers are shown with the persona matching this story's own mode,
        // same reasoning as `list`'s author field: the identity a hobby-mode
        // story's audience sees should be their hobby persona, not whichever
        // mode they currently happen to be browsing in.
        // `s.mode` came back from the DB's own CHECK-constrained column
        // (only ever 'hobby'/'work'), not from request input, so splicing it
        // into a quoted SQL literal here carries no injection risk.
        let rows = try await req.db.sql().raw("""
            SELECT u.id, \(unsafeRaw: PersonaSQL.expr("display_name", modeRef: "'\(s.mode)'")) AS display_name,
              u.avatar_color, \(unsafeRaw: PersonaSQL.expr("avatar_url", modeRef: "'\(s.mode)'")) AS avatar_url, sv.viewed_at
            FROM story_views sv JOIN users u ON u.id = sv.viewer_id
            WHERE sv.story_id = \(uuid: id) AND sv.viewer_id <> \(uuid: req.userID)
            ORDER BY sv.viewed_at DESC
            """).all(decoding: ViewerRow.self)
        return DataListResponse(data: rows)
    }
    static func remove(_ req: Request) async throws -> StatusOKMsg {
        struct D: Decodable { let id: String }
        let del = try await req.db.sql().raw("DELETE FROM stories WHERE id = \(uuid: req.parameters.get("id")!) AND author_id = \(uuid: req.userID) RETURNING id")
            .all(decoding: D.self)
        guard !del.isEmpty else { throw InlineError(.notFound, "Story not found") }
        return StatusOKMsg()
    }
}

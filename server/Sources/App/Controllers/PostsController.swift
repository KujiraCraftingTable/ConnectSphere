import Vapor
import SQLKit

/// Port of `backend/src/controllers/postsController.js` + `postRoutes.js`.
/// AI side effects (mode-mismatch notification, tag extraction, chunk cleanup)
/// are deferred to Phase 3/5 — they don't touch the synchronous response.
struct PostsController {
    static func register(routes: any RoutesBuilder) {
        let posts = routes.grouped("posts").grouped(AuthMiddleware())

        posts.get(use: list)
        posts.post(use: create)
        posts.post("analyze", use: analyze)
        posts.get("deleted", use: listDeleted)
        posts.get("saved", use: listSaved)
        posts.get("comments", "deleted", use: listDeletedComments)
        posts.get(":id", use: getOne)
        posts.delete(":id", use: softDelete)
        posts.patch(":id", use: update)
        posts.post(":id", "restore", use: restore)
        posts.post(":id", "poll", "vote", use: pollVote)
        posts.post(":id", "share", use: share)
        posts.post(":id", "report", use: report)

        // Nested interactions (like / comments / hide / save) — mergeParams.
        InteractionsController.register(routes: posts.grouped(":id"))
    }

    static func clamp(_ v: Int?, _ def: Int, _ lo: Int, _ hi: Int) -> Int { min(max(v ?? def, lo), hi) }

    // MARK: GET /api/posts

    static func list(_ req: Request) async throws -> PaginatedResponse<PostObject> {
        let db = req.db.sql()
        let mode = try? req.query.get(String.self, at: "mode")
        let authorID = try? req.query.get(String.self, at: "author_id")
        let tag = (try? req.query.get(String.self, at: "tag")).flatMap { $0.isEmpty ? nil : $0 }
        let connections = (try? req.query.get(String.self, at: "filter")) == "connections"
        let limit = clamp(try? req.query.get(Int.self, at: "limit"), 20, 1, 50)
        let offset = max((try? req.query.get(Int.self, at: "offset")) ?? 0, 0)
        let f = PostStore.FeedFilters(mode: mode, authorID: authorID, tag: tag,
                                      connectionsOnly: connections, limit: limit, offset: offset)
        async let rows = PostStore.findAll(viewer: req.userID, f, on: db)
        async let total = PostStore.countAll(viewer: req.userID, f, on: db)
        return PaginatedResponse(data: try await rows, pagination: .init(total: try await total, limit: limit, offset: offset))
    }

    // MARK: GET /api/posts/:id

    static func getOne(_ req: Request) async throws -> DataResponse<PostObject> {
        guard let post = try await PostStore.findById(req.parameters.get("id")!, viewer: req.userID, on: req.db.sql()) else {
            throw Abort(.notFound, reason: "Post not found")
        }
        return DataResponse(data: post)
    }

    // MARK: POST /api/posts/analyze  (deferred to Phase 5 — stub keyword fast-path only)

    struct AnalyzeBody: Content { var content: String?; var currentMode: String? }
    struct AnalyzeResponse: Content {
        var suggestedMode: String
        var confidence: Double
        var reason: String
        var isMismatch: Bool
    }
    static func analyze(_ req: Request) async throws -> AnalyzeResponse {
        let b = try req.content.decode(AnalyzeBody.self)
        guard let content = b.content?.trimmingCharacters(in: .whitespaces), !content.isEmpty else {
            throw InlineError(.badRequest, "content is required")
        }
        // Phase 5 will call the Ollama-backed analyzer. Until then: neutral/no-op,
        // which matches the Node fallback path on Ollama failure.
        return AnalyzeResponse(suggestedMode: "neutral", confidence: 0, reason: "", isMismatch: false)
    }

    // MARK: POST /api/posts

    struct CreateBody: Content {
        var content: String?
        var mode: String?
        var privacy: String?
        var post_type: String?
        var image_url: String?
        var image_urls: [String]?
        var link_url: String?
        var article_title: String?
        var hashtags: [String]?
        var show_ai_tags: Bool?
        var options: [String]?
        var endsAt: String?
        var eventData: EventDataIn?
        struct EventDataIn: Content {
            var title: String?
            var location: String?
            var startsAt: String?
            var endsAt: String?
        }
    }

    static func create(_ req: Request) async throws -> Response {
        let b = try req.content.decode(CreateBody.self)
        let hashtags = b.hashtags ?? []
        let showAi = b.show_ai_tags ?? false
        guard ["hobby", "work"].contains(b.mode ?? "") else {
            throw InlineError(.badRequest, "mode must be hobby or work")
        }
        let mode = b.mode!
        let postType = b.post_type ?? "text"

        let post: PostObject
        if postType == "poll" {
            post = try await PostService.createPollPost(
                authorID: req.userID, communityID: nil, content: b.content, options: b.options,
                endsAt: b.endsAt, hashtags: hashtags, showAiTags: showAi, mode: mode, privacy: b.privacy, on: req.db)
        } else if postType == "event" {
            post = try await PostService.createEventPost(
                authorID: req.userID, communityID: nil, content: b.content,
                eventTitle: b.eventData?.title, eventLocation: b.eventData?.location,
                eventStartsAt: b.eventData?.startsAt, eventEndsAt: b.eventData?.endsAt,
                hashtags: hashtags, showAiTags: showAi, mode: mode, privacy: b.privacy, on: req.db)
        } else {
            let imageUrls = normalizeImageUrls(b.image_urls)
            let hasContent = !(b.content?.trimmingCharacters(in: .whitespaces).isEmpty ?? true)
            if !hasContent && (b.link_url?.isEmpty ?? true) && imageUrls == nil {
                throw InlineError(.badRequest, "content, link_url or image_urls is required")
            }
            if let c = b.content, c.count > 2000 {
                throw InlineError(.badRequest, "content must be at most 2000 characters")
            }
            guard let created = try await PostStore.create(.init(
                authorID: req.userID, content: b.content?.trimmingCharacters(in: .whitespaces) ?? "",
                mode: mode, privacy: b.privacy ?? "public",
                imageUrl: b.image_url?.nilIfEmpty, imageUrls: imageUrls, linkUrl: b.link_url?.nilIfEmpty,
                articleTitle: b.article_title?.nilIfEmpty, sharedPostID: nil,
                hashtags: hashtags, showAiTags: showAi), on: req.db)
            else { throw Abort(.internalServerError) }
            post = created
            // TODO(phase 5): runPostBackground (mode-check notification + tag queue)
        }
        let res = try await DataResponse(data: post).encodeResponse(for: req)
        res.status = .created
        return res
    }

    /// Port of `utils/postInput.js#normalizeImageUrls`.
    static func normalizeImageUrls(_ urls: [String]?) -> [String]? {
        guard let urls else { return nil }
        let clean = urls.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.prefix(10)
        return clean.isEmpty ? nil : Array(clean)
    }

    // MARK: POST /api/posts/:id/share

    struct ShareBody: Content { var content: String?; var mode: String?; var privacy: String? }

    static func share(_ req: Request) async throws -> Response {
        let b = try req.content.decode(ShareBody.self)
        guard ["hobby", "work"].contains(b.mode ?? "") else {
            throw InlineError(.badRequest, "mode must be hobby or work")
        }
        guard let original = try await PostStore.findById(req.parameters.get("id")!, viewer: req.userID, on: req.db.sql()) else {
            throw Abort(.notFound, reason: "Post not found")
        }
        let rootID = original.shared_post_id ?? original.id
        guard let post = try await PostStore.create(.init(
            authorID: req.userID, content: b.content?.trimmingCharacters(in: .whitespaces) ?? "",
            mode: b.mode!, privacy: b.privacy ?? "public",
            imageUrl: nil, imageUrls: nil, linkUrl: nil, articleTitle: nil,
            sharedPostID: rootID, hashtags: [], showAiTags: false), on: req.db)
        else { throw Abort(.internalServerError) }
        try await req.db.sql().raw("UPDATE posts SET share_count = share_count + 1 WHERE id = \(uuid: rootID)").run()
        // TODO(phase 3): post_shared notification
        let res = try await DataResponse(data: post).encodeResponse(for: req)
        res.status = .created
        return res
    }

    // MARK: DELETE /api/posts/:id

    struct DeleteResponse: Content { var status = "ok"; var message = "Post deleted" }
    static func softDelete(_ req: Request) async throws -> DeleteResponse {
        try await PostService.deletePost(requesterID: req.userID, postID: req.parameters.get("id")!, on: req.db)
        // TODO(phase 5): deletePostChunks
        return DeleteResponse()
    }

    // MARK: POST /api/posts/:id/restore

    static func restore(_ req: Request) async throws -> DataResponse<PostObject> {
        DataResponse(data: try await PostService.restorePost(requesterID: req.userID, postID: req.parameters.get("id")!, on: req.db))
    }

    // MARK: PATCH /api/posts/:id

    struct UpdateBody: Content {
        var content: String?
        var privacy: String?
        var image_url: String?
        var image_urls: [String]?
        var link_url: String?
        var article_title: String?
    }
    static func update(_ req: Request) async throws -> DataResponse<PostObject> {
        let id = req.parameters.get("id")!
        let sdb = req.db.sql()
        guard let meta = try await PostStore.findMeta(id, on: sdb) else { throw Abort(.notFound, reason: "Post not found") }
        guard meta.author_id == req.userID else { throw Abort(.forbidden, reason: "Forbidden") }

        let b = try req.content.decode(UpdateBody.self)
        let contentProvided = (try? req.content.decode([String: AnyCodableValue].self))?.keys.contains("content") ?? false
        var imageUrls: [String]? = nil
        if let arr = b.image_urls {
            let clean = arr.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.prefix(10)
            imageUrls = clean.isEmpty ? nil : Array(clean)
        }
        let result = try await PostStore.updatePost(
            id, content: contentProvided ? (b.content ?? "").trimmingCharacters(in: .whitespaces) : nil,
            contentProvided: contentProvided, privacy: b.privacy?.nilIfEmpty,
            imageUrl: b.image_url?.nilIfEmpty, imageUrls: imageUrls,
            linkUrl: b.link_url?.nilIfEmpty, articleTitle: b.article_title?.nilIfEmpty, on: sdb)
        switch result {
        case .empty: throw Abort(.badRequest, reason: "A post must have a caption, image, or link")
        case .notFound: throw Abort(.notFound, reason: "Post not found or already deleted")
        case .updated(let post): return DataResponse(data: post)
        }
    }

    // MARK: GET /api/posts/deleted | /saved

    struct PagedNoTotal<T: Content>: Content { var data: [T]; var pagination: P; struct P: Content { var limit: Int; var offset: Int } }

    static func listDeleted(_ req: Request) async throws -> PagedNoTotal<PostObject> {
        let limit = clamp(try? req.query.get(Int.self, at: "limit"), 20, 1, 50)
        let offset = max((try? req.query.get(Int.self, at: "offset")) ?? 0, 0)
        return PagedNoTotal(data: try await PostStore.listDeleted(req.userID, limit: limit, offset: offset, on: req.db.sql()),
                            pagination: .init(limit: limit, offset: offset))
    }
    static func listSaved(_ req: Request) async throws -> PagedNoTotal<PostObject> {
        let limit = clamp(try? req.query.get(Int.self, at: "limit"), 20, 1, 50)
        let offset = max((try? req.query.get(Int.self, at: "offset")) ?? 0, 0)
        return PagedNoTotal(data: try await PostStore.listSaved(req.userID, limit: limit, offset: offset, on: req.db.sql()),
                            pagination: .init(limit: limit, offset: offset))
    }

    // MARK: GET /api/posts/comments/deleted

    struct DeletedComment: Content {
        var id: String
        var post_id: String
        @NullCoded var content: String?
        var created_at: Date
        @NullCoded var deleted_at: Date?
        @NullCoded var parent_comment_id: String?
        var like_count: Int
    }
    static func listDeletedComments(_ req: Request) async throws -> PagedNoTotal<DeletedComment> {
        let limit = clamp(try? req.query.get(Int.self, at: "limit"), 20, 1, 50)
        let offset = max((try? req.query.get(Int.self, at: "offset")) ?? 0, 0)
        let rows = try await req.db.sql().raw("""
            SELECT c.id, c.post_id, c.content, c.created_at, c.deleted_at, c.parent_comment_id, c.like_count
            FROM comments c JOIN posts p ON p.id = c.post_id
            WHERE c.author_id = \(uuid: req.userID) AND c.status = 'deleted'
            ORDER BY c.deleted_at DESC NULLS LAST
            LIMIT \(bind: limit) OFFSET \(bind: offset)
            """).all(decoding: DeletedComment.self)
        return PagedNoTotal(data: rows, pagination: .init(limit: limit, offset: offset))
    }

    // MARK: poll vote / report

    struct PollVoteBody: Content { var optionId: String? }
    struct OKMessage: Content { var status = "ok"; var message: String }
    static func pollVote(_ req: Request) async throws -> OKMessage {
        guard let optionID = try req.content.decode(PollVoteBody.self).optionId else {
            throw Abort(.badRequest, reason: "optionId is required")
        }
        try await PostService.voteOnPoll(postID: req.parameters.get("id")!, userID: req.userID, optionID: optionID, on: req.db)
        return OKMessage(message: "Vote recorded")
    }

    // report → Phase 3 (reportService). Minimal stub kept out until then.
    static func report(_ req: Request) async throws -> Response {
        throw Abort(.notImplemented, reason: "reporting ported in Phase 3")
    }
}

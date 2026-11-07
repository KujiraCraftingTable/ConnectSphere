import Vapor
import SQLKit

/// Posts: create, edit, delete, share, drafts. AI side effects (mode-mismatch
/// notification, tag extraction, chunk cleanup) never touch the synchronous response.
struct PostsController {
    static func register(routes: any RoutesBuilder) {
        let posts = routes.grouped("posts").grouped(AuthMiddleware())

        posts.get(use: list)
        posts.post(use: create)
        posts.post("analyze", use: analyze)
        posts.get("deleted", use: listDeleted)
        posts.get("saved", use: listSaved)
        posts.get("drafts", use: listDrafts)
        posts.delete(":id", "draft", use: deleteDraft)
        posts.post(":id", "unschedule", use: unschedule)
        posts.post(":id", "publish", use: publishScheduled)
        posts.get("comments", "deleted", use: listDeletedComments)
        posts.get(":id", use: getOne)
        posts.delete(":id", use: softDelete)
        posts.patch(":id", use: update)
        posts.post(":id", "restore", use: restore)
        posts.post(":id", "poll", "vote", use: pollVote)
        posts.delete(":id", "poll", "vote", use: pollUnvote)
        posts.post(":id", "share", use: share)
        posts.post(":id", "report", use: report)

        // Nested interactions (like / comments / hide / save), mergeParams.
        InteractionsController.register(routes: posts.grouped(":id"))
    }

    static func clamp(_ v: Int?, _ def: Int, _ lo: Int, _ hi: Int) -> Int { min(max(v ?? def, lo), hi) }

    // MARK: GET /api/posts

    static func list(_ req: Request) async throws -> PaginatedResponse<PostObject> {
        let db = req.db.sql()
        let mode = try? req.query.get(String.self, at: "mode")
        let authorID = try? req.query.get(String.self, at: "author_id")
        let tag = (try? req.query.get(String.self, at: "tag")).flatMap { $0.isEmpty ? nil : $0 }
        let search = (try? req.query.get(String.self, at: "search")).flatMap { $0.isEmpty ? nil : $0 }
        let filter = try? req.query.get(String.self, at: "filter")
        let connections = filter == "connections"
        let limit = clamp(try? req.query.get(Int.self, at: "limit"), 20, 1, 50)
        let offset = req.pageOffset
        // Home's Connections / Following tabs show items for sale like any post.
        let homeFeed = (connections || filter == "following") && authorID == nil && tag == nil && search == nil
        let f = PostStore.FeedFilters(mode: mode, authorID: authorID, tag: tag, search: search,
                                      connectionsOnly: connections, followingOnly: filter == "following",
                                      limit: limit, offset: offset,
                                      includeListings: homeFeed, listingsForSaleOnly: homeFeed)
        async let rows = PostStore.findAll(viewer: req.userID, f, on: db)
        async let total = PostStore.countAll(viewer: req.userID, f, on: db)
        return PaginatedResponse(data: try await rows, pagination: .init(total: try await total, limit: limit, offset: offset))
    }

    // MARK: GET /api/posts/:id

    static func getOne(_ req: Request) async throws -> DataResponse<PostObject> {
        // Authors can open their own posts that aren't public yet (pending
        // approval, declined) from Manage your content.
        guard let post = try await PostStore.findById(req.parameters.get("id")!, viewer: req.userID,
                                                      includeOwnUnpublished: true, on: req.db.sql()) else {
            throw Abort(.notFound, reason: "Post not found")
        }
        return DataResponse(data: post)
    }

    // MARK: POST /api/posts/analyze

    struct AnalyzeBody: Content { var content: String?; var currentMode: String? }
    struct AnalyzeResponse: Content {
        var suggestedMode: String
        var confidence: Double
        var reason: String
        var fast: Bool?
        var isMismatch: Bool
    }
    static func analyze(_ req: Request) async throws -> AnalyzeResponse {
        let b = try req.content.decode(AnalyzeBody.self)
        guard let content = b.content?.trimmingCharacters(in: .whitespaces), !content.isEmpty else {
            throw InlineError(.badRequest, "content is required")
        }
        let r = await PostAnalyzeService.analyze(req.ollama, content, logger: req.logger)
        let isMismatch = r.confidence >= 0.75 && r.suggestedMode != "neutral"
            && (b.currentMode.map { !$0.isEmpty && r.suggestedMode != $0 } ?? false)
        return AnalyzeResponse(suggestedMode: r.suggestedMode, confidence: r.confidence, reason: r.reason,
                               fast: r.fast, isMismatch: isMismatch)
    }

    // MARK: POST /api/posts

    struct CreateBody: Content {
        var content: String?
        /// "markdown" when the app wrote the text with Markdown; absent = plain.
        var content_format: String?
        /// Community posts only: "public" or "members" (the default).
        var community_audience: String?
        var mode: String?
        var privacy: String?
        var post_type: String?
        var image_url: String?
        var image_urls: [String]?
        var image_alts: [String]?
        var link_url: String?
        var article_title: String?
        var hashtags: [String]?
        /// now (default) | draft | schedule
        var publish: String?
        /// When a scheduled post goes out (ISO 8601).
        var publish_at: String?
        /// A draft (or scheduled post) of yours this one replaces: saving a
        /// draft again, or publishing it, sends the whole post plus this id,
        /// and the old version is removed once the new one is saved.
        var replaces_draft: String?
        var options: [String]?
        var endsAt: String?
        var eventData: EventDataIn?
        var jobData: JobDataIn?
        var listingData: ListingDataIn?
        /// A marketplace listing (community posts only); the description is `content`.
        struct ListingDataIn: Content {
            var title: String?
            /// Whole VND; 0 = free.
            var price: Int64?
            var condition: String?
            var location: String?
            var autoReply: String?
            var hideFromFriends: Bool?
            /// Where it is, picked on a map (both or neither).
            var latitude: Double?
            var longitude: Double?
            /// Re-up automatically (migration 095); omit for never.
            var autoReup: PostObject.ListingData.AutoReup?
        }
        struct EventDataIn: Content {
            var title: String?
            var location: String?
            var startsAt: String?
            var endsAt: String?
        }
        struct JobDataIn: Content {
            var title: String?
            var company: String?
            var location: String?
            var employmentType: String?
            var salaryRange: String?
            var applicationDeadline: String?
            /// Post as this company page (you must be one of its admins).
            var companyId: String?
            var workFormat: String?
            var level: String?
            /// VND million / month.
            var salaryMin: Int?
            var salaryMax: Int?
            var skills: [String]?
        }
    }

    static func create(_ req: Request) async throws -> Response {
        let b = try req.content.decode(CreateBody.self)
        let hashtags = b.hashtags ?? []
        guard ["hobby", "work"].contains(b.mode ?? "") else {
            throw InlineError(.badRequest, "mode must be hobby or work")
        }
        let mode = b.mode!
        _ = try PostStore.validatedPrivacy(b.privacy)
        let postType = b.post_type ?? "text"
        let publishing = try Publishing.from(b.publish, at: b.publish_at)
        try await checkReplacedDraft(b.replaces_draft, req)

        var post: PostObject
        if postType == "poll" {
            post = try await PostService.createPollPost(
                authorID: req.userID, communityID: nil, content: b.content, options: b.options,
                endsAt: b.endsAt, hashtags: hashtags, mode: mode, privacy: b.privacy, publishing: publishing, on: req.db)
        } else if postType == "event" {
            post = try await PostService.createEventPost(
                authorID: req.userID, communityID: nil, content: b.content,
                eventTitle: b.eventData?.title, eventLocation: b.eventData?.location,
                eventStartsAt: b.eventData?.startsAt, eventEndsAt: b.eventData?.endsAt,
                hashtags: hashtags, mode: mode, privacy: b.privacy, publishing: publishing, on: req.db)
        } else if postType == "job" {
            post = try await PostService.createJobPost(
                authorID: req.userID, communityID: nil, content: b.content,
                jobTitle: b.jobData?.title, jobCompany: b.jobData?.company, jobLocation: b.jobData?.location,
                employmentType: b.jobData?.employmentType, salaryRange: b.jobData?.salaryRange,
                applicationDeadline: b.jobData?.applicationDeadline, details: b.jobData,
                hashtags: hashtags, mode: mode, privacy: b.privacy, publishing: publishing, on: req.db)
        } else {
            let imageUrls = try normalizeImageUrls(b.image_urls)
            let hasContent = !(b.content?.trimmedText.isEmpty ?? true)
            if !hasContent && (b.link_url?.isEmpty ?? true) && imageUrls == nil {
                throw InlineError(.badRequest, "content, link_url or image_urls is required")
            }
            if let c = b.content, c.count > 2000 {
                throw InlineError(.badRequest, "content must be at most 2000 characters")
            }
            guard let created = try await PostStore.create(.init(
                authorID: req.userID, content: b.content?.trimmedText ?? "",
                mode: mode, privacy: b.privacy ?? "public",
                imageUrl: try MediaPath.thumbnail(b.image_url, hasLink: b.link_url?.nilIfEmpty != nil), imageUrls: imageUrls, linkUrl: b.link_url?.nilIfEmpty,
                articleTitle: b.article_title?.nilIfEmpty, sharedPostID: nil,
                hashtags: hashtags, publishing: publishing), on: req.db)
            else { throw Abort(.internalServerError) }
            post = created
        }
        if b.image_alts != nil {
            post.image_alts = try await PostStore.setImageAlts(post.id, b.image_alts, on: req.db.sql())
        }
        if b.content_format != nil {
            post.content_format = try await PostStore.setContentFormat(post.id, b.content_format, on: req.db.sql())
        }

        if let old = b.replaces_draft {
            // Saved fine, so the version it replaces can go.
            try await PostStore.deleteUnpublished(old, author: req.userID, on: req.db.sql())
        }
        if publishing.isLive { await PostPublisher.afterPublish(req, post: post) }
        let res = try await DataResponse(data: post).encodeResponse(for: req)
        res.status = .created
        return res
    }

    /// `replaces_draft` must be one of your own drafts or scheduled posts,
    /// checked before saving so a bad id can't leave two copies behind.
    static func checkReplacedDraft(_ id: String?, _ req: Request) async throws {
        guard let id else { return }
        guard UUID(uuidString: id) != nil,
              try await PostStore.isOwnUnpublished(id, author: req.userID, on: req.db.sql()) else {
            throw InlineError(.notFound, "Draft not found")
        }
    }

    // MARK: drafts, GET /api/posts/drafts, DELETE /api/posts/:id/draft

    struct DraftsResponse: Content { var data: [PostObject] }

    static func listDrafts(_ req: Request) async throws -> DraftsResponse {
        DraftsResponse(data: try await PostStore.listUnpublished(req.userID, on: req.db.sql()))
    }

    static func deleteDraft(_ req: Request) async throws -> DeleteResponse {
        guard let id = UUID(uuidString: req.parameters.get("id") ?? ""),
              try await PostStore.deleteUnpublished(id.uuidString, author: req.userID, on: req.db.sql()) else {
            throw InlineError(.notFound, "Draft not found")
        }
        return DeleteResponse(message: "Draft deleted")
    }

    /// A scheduled post back to a draft (not going out after all).
    static func unschedule(_ req: Request) async throws -> DeleteResponse {
        struct I: Decodable { let id: String }
        guard let id = UUID(uuidString: req.parameters.get("id") ?? ""),
              try await req.db.sql().raw("""
                UPDATE posts SET status = 'draft', publish_at = NULL
                WHERE id = \(uuid: id.uuidString) AND author_id = \(uuid: req.userID) AND status = 'scheduled'
                RETURNING id::text AS id
                """).first(decoding: I.self) != nil else {
            throw InlineError(.notFound, "Scheduled post not found")
        }
        return DeleteResponse(message: "Moved to drafts")
    }

    /// "Publish now" on a scheduled post. Its dates were checked against the
    /// scheduled time, so they're checked again against now first.
    static func publishScheduled(_ req: Request) async throws -> DataResponse<PostObject> {
        guard let id = UUID(uuidString: req.parameters.get("id") ?? "")?.uuidString else {
            throw InlineError(.notFound, "Scheduled post not found")
        }
        let db = req.db.sql()
        guard try await PostStore.isOwnUnpublished(id, author: req.userID, on: db) else {
            throw InlineError(.notFound, "Scheduled post not found")
        }
        if let problem = try await PostPublisher.staleDates(id, on: db) { throw InlineError(.badRequest, problem) }
        guard let live = try await PostPublisher.publishNow(id, author: req.userID, on: db) else {
            throw InlineError(.notFound, "Scheduled post not found")
        }
        await PostPublisher.didGoLive(live, app: req.application, queue: BackgroundJobs.queue(for: req), logger: req.logger, notify: false)
        guard let post = try await PostStore.findById(id, viewer: req.userID, on: db) else { throw Abort(.internalServerError) }
        return DataResponse(data: post)
    }

    /// Cleans the image list: our own uploads only (400 otherwise), at most 10.
    static func normalizeImageUrls(_ urls: [String]?) throws -> [String]? {
        guard let clean = try MediaPath.uploaded(urls)?.prefix(10), !clean.isEmpty else { return nil }
        return Array(clean)
    }

    // MARK: POST /api/posts/:id/share

    struct ShareBody: Content { var content: String?; var mode: String?; var privacy: String? }

    static func share(_ req: Request) async throws -> Response {
        let b = try req.content.decode(ShareBody.self)
        guard ["hobby", "work"].contains(b.mode ?? "") else {
            throw InlineError(.badRequest, "mode must be hobby or work")
        }
        let privacy = try PostStore.validatedPrivacy(b.privacy) ?? "public"
        guard let original = try await PostStore.findById(req.parameters.get("id")!, viewer: req.userID, on: req.db.sql()) else {
            throw Abort(.notFound, reason: "Post not found")
        }
        // Hobby and Work are separate datasets: a post can't be carried across.
        guard original.mode == b.mode else {
            throw Abort(.badRequest, reason: "A post can only be shared in the mode it was posted in")
        }
        // Marketplace items are passed on by message only, never reposted.
        guard original.post_type != "listing" else {
            throw Abort(.badRequest, reason: "Listings can only be shared in a message")
        }
        let rootID = original.shared_post_id ?? original.id
        guard let post = try await PostStore.create(.init(
            authorID: req.userID, content: b.content?.trimmedText ?? "",
            mode: b.mode!, privacy: privacy,
            imageUrl: nil, imageUrls: nil, linkUrl: nil, articleTitle: nil,
            sharedPostID: rootID, hashtags: []), on: req.db)
        else { throw Abort(.internalServerError) }
        try await req.db.sql().raw("UPDATE posts SET share_count = share_count + 1 WHERE id = \(uuid: rootID)").run()
        struct RA: Decodable { let author_id: String }
        if let root = try? await req.db.sql().raw("SELECT author_id::text AS author_id FROM posts WHERE id = \(uuid: rootID)")
            .first(decoding: RA.self), root.author_id != req.userID {
            NotifyService.dispatchSocial(req, .init(
                type: "post_shared", actorID: req.userID, recipientID: root.author_id,
                postID: rootID, checkID: post.id))
        }
        let res = try await DataResponse(data: post).encodeResponse(for: req)
        res.status = .created
        return res
    }

    // MARK: DELETE /api/posts/:id

    struct DeleteResponse: Content { var status = "ok"; var message = "Post deleted" }
    static func softDelete(_ req: Request) async throws -> DeleteResponse {
        let id = req.parameters.get("id")!
        try await PostService.deletePost(requesterID: req.userID, postID: id, on: req.db)
        try? await ChunkService.deletePostChunks(id, on: req.db.sql())
        return DeleteResponse()
    }

    // MARK: POST /api/posts/:id/restore

    static func restore(_ req: Request) async throws -> DataResponse<PostObject> {
        let post = try await PostService.restorePost(requesterID: req.userID, postID: req.parameters.get("id")!, on: req.db)
        await BackgroundJobs.refreshEmbedding(req, .post, id: post.id)
        return DataResponse(data: post)
    }

    // MARK: PATCH /api/posts/:id

    struct UpdateBody: Content {
        var content: String?
        /// Sent with `content`: how the new text is written ("markdown" or "plain").
        var content_format: String?
        var privacy: String?
        var image_url: String?
        var image_urls: [String]?
        /// Sent alongside `image_urls` when media changes; on its own it
        /// re-describes the current media.
        var image_alts: [String]?
        var link_url: String?
        var article_title: String?
        /// Community posts only: "public" or "members".
        var community_audience: String?
        /// The post's own `#tags`; when present they replace the old ones.
        var hashtags: [String]?
    }
    static func update(_ req: Request) async throws -> DataResponse<PostObject> {
        let id = req.parameters.get("id")!
        let sdb = req.db.sql()
        guard let meta = try await PostStore.findMeta(id, on: sdb) else { throw Abort(.notFound, reason: "Post not found") }
        guard meta.author_id == req.userID else { throw Abort(.forbidden, reason: "Forbidden") }
        // A listing is bound to one item: its text and photos change through the listing.
        guard meta.post_type != "listing" else { throw Abort(.badRequest, reason: "Edit the listing instead") }
        struct Old: Decodable { let content: String?; let image_urls: [String]?; let image_alts: [String]? }
        let old = try await sdb.raw("SELECT content, image_urls, image_alts FROM posts WHERE id = \(uuid: id)").first(decoding: Old.self)
        let oldContent = old?.content

        let b = try req.content.decode(UpdateBody.self)
        if let a = b.community_audience, !PostStore.communityAudiences.contains(a) {
            throw Abort(.badRequest, reason: "community_audience must be public or members")
        }
        let privacy = try PostStore.validatedPrivacy(b.privacy)
        // Same cap as create; the content column is TEXT, so only this stops a huge edit.
        if let c = b.content, c.count > 2000 { throw InlineError(.badRequest, "content must be at most 2000 characters") }
        let contentProvided = (try? req.content.decode([String: AnyCodableValue].self))?.keys.contains("content") ?? false
        let imageUrls = try normalizeImageUrls(b.image_urls)
        let result = try await PostStore.updatePost(
            id, content: contentProvided ? (b.content ?? "").trimmedText : nil,
            contentProvided: contentProvided, privacy: privacy,
            imageUrl: try MediaPath.thumbnail(b.image_url, hasLink: b.link_url?.nilIfEmpty != nil), imageUrls: imageUrls,
            linkUrl: b.link_url?.nilIfEmpty, articleTitle: b.article_title?.nilIfEmpty, on: sdb)
        switch result {
        case .empty: throw Abort(.badRequest, reason: "A post must have a caption, image, or link")
        case .notFound: throw Abort(.notFound, reason: "Post not found or already deleted")
        case .updated(var post):
            if let tags = b.hashtags {
                try await PostStore.replaceUserTags(id, tags, on: sdb)
                if let fresh = try await PostStore.findById(id, viewer: req.userID, on: sdb) { post = fresh }
            }
            if contentProvided, b.content_format != nil {
                post.content_format = try await PostStore.setContentFormat(id, b.content_format, on: sdb)
            }
            if let a = b.community_audience, post.community != nil {
                post.community?.audience = try await PostStore.setCommunityAudience(id, a, on: sdb)
            }
            // The app resends the current media on every edit, so only a real
            // change of media drops the old descriptions (they described other
            // photos); otherwise they stay unless new ones were sent.
            let mediaChanged = (post.image_urls ?? []) != (old?.image_urls ?? [])
            if b.image_alts != nil || mediaChanged {
                post.image_alts = try await PostStore.setImageAlts(post.id, b.image_alts, on: sdb)
            }
            if (post.content ?? "") != (oldContent ?? "") {
                await BackgroundJobs.refreshPostAfterContentEdit(req, postID: post.id, content: post.content ?? "")
                await TranslationService.enqueue(req, .post, id: post.id)
            } else {
                await BackgroundJobs.refreshEmbedding(req, .post, id: post.id)   // e.g. article title
            }
            return DataResponse(data: post)
        }
    }

    // MARK: GET /api/posts/deleted | /saved

    struct PagedNoTotal<T: Content>: Content { var data: [T]; var pagination: P; struct P: Content { var limit: Int; var offset: Int } }

    static func listDeleted(_ req: Request) async throws -> PagedNoTotal<PostObject> {
        let limit = clamp(try? req.query.get(Int.self, at: "limit"), 20, 1, 50)
        let offset = req.pageOffset
        return PagedNoTotal(data: try await PostStore.listDeleted(req.userID, limit: limit, offset: offset, on: req.db.sql()),
                            pagination: .init(limit: limit, offset: offset))
    }
    static func listSaved(_ req: Request) async throws -> PagedNoTotal<PostObject> {
        let limit = clamp(try? req.query.get(Int.self, at: "limit"), 20, 1, 50)
        let offset = req.pageOffset
        // Saved posts and saved Marketplace items are listed separately.
        let kind = (try? req.query.get(String.self, at: "kind")) ?? "posts"
        guard ["posts", "listings"].contains(kind) else { throw Abort(.badRequest, reason: "kind must be posts or listings") }
        return PagedNoTotal(data: try await PostStore.listSaved(req.userID, listings: kind == "listings",
                                                                limit: limit, offset: offset, on: req.db.sql()),
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
        let offset = req.pageOffset
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

    static func pollUnvote(_ req: Request) async throws -> OKMessage {
        try await PostService.voteOnPoll(postID: req.parameters.get("id")!, userID: req.userID, optionID: nil, on: req.db)
        return OKMessage(message: "Vote removed")
    }

    static func report(_ req: Request) async throws -> Response {
        try await ReportsController.reportPost(req)
    }
}

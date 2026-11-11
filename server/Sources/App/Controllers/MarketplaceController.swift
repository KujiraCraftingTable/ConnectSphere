import Vapor
import SQLKit

/// The Marketplace tab and a listing's own page. A listing is a community
/// post (migration 072), so it's created through `POST /communities/:id/posts`
/// and deleted like any post; this covers browsing and the seller's edits.
struct MarketplaceController {
    static func register(routes: any RoutesBuilder) {
        routes.grouped("marketplace").grouped(AuthMiddleware()).get(use: list)
        let l = routes.grouped("listings").grouped(AuthMiddleware())
        l.post(use: create)
        l.get(":id", use: get)
        l.patch(":id", use: update)
        l.post(":id", "reup", use: reup)
        l.patch(":id", "items", ":itemId", use: updateItem)
        l.post(":id", "items", ":itemId", "ask", use: askAboutItem)
    }

    /// GET /api/marketplace?mode=&q=&community_id=&seller_id=&limit=&offset=
    /// With `seller_id`: that seller's items, sold ones too (after the rest).
    static func list(_ req: Request) async throws -> DataListResponse<PostObject> {
        guard let mode = try? req.query.get(String.self, at: "mode"), ["hobby", "work"].contains(mode) else {
            throw Abort(.badRequest, reason: "mode must be hobby or work")
        }
        let q = (try? req.query.get(String.self, at: "q"))?.trimmedText.nilIfEmpty
        if let q, q.count > 100 { throw Abort(.badRequest, reason: "Search is too long") }
        let communityID = (try? req.query.get(String.self, at: "community_id"))?.nilIfEmpty
        if let communityID, UUID(uuidString: communityID) == nil { throw Abort(.badRequest, reason: "Invalid community") }
        let sellerID = (try? req.query.get(String.self, at: "seller_id"))?.nilIfEmpty
        if let sellerID, UUID(uuidString: sellerID) == nil { throw Abort(.badRequest, reason: "Invalid seller") }
        let limit = PostsController.clamp(try? req.query.get(Int.self, at: "limit"), 30, 1, 50)
        let offset = req.pageOffset
        return DataListResponse(data: try await ListingStore.marketplace(
            viewer: req.userID, mode: mode, query: q, communityID: communityID, sellerID: sellerID,
            limit: limit, offset: offset, on: req.db.sql()))
    }

    struct CreateBody: Content {
        var content: String?
        /// "markdown" when the description was written with Markdown.
        var content_format: String?
        var mode: String?
        var listingData: PostsController.CreateBody.ListingDataIn?
        /// Also list it in these communities (0–5). It shows there as a post.
        var community_ids: [String]?
    }

    /// POST /api/listings, a new listing in the Marketplace.
    static func create(_ req: Request) async throws -> Response {
        try await OfficialAccount.refuse(req.userID, "can't sell in the Marketplace", on: req.db.sql())
        let b = try req.content.decode(CreateBody.self)
        try ModerationGate.check([b.content, b.listingData?.title, b.listingData?.location, b.listingData?.autoReply]
                                 + (b.listingData?.items ?? []).map(\.title), .text)
        guard let mode = b.mode, ["hobby", "work"].contains(mode) else {
            throw Abort(.badRequest, reason: "mode must be hobby or work")
        }
        try req.requireNotBanned(in: mode)
        try req.requireNotRestricted(in: mode)
        var (post, liveIn) = try await PostService.createListingPost(
            authorID: req.userID, mode: mode, content: b.content, details: b.listingData,
            communityIDs: b.community_ids, on: req.db)
        if b.content_format != nil {
            post.content_format = try await PostStore.setContentFormat(post.id, b.content_format, on: req.db.sql())
        }
        await TranslationService.enqueue(req, .post, id: post.id)
        await ModerationScan.enqueue(req, .post, id: post.id)
        for communityID in liveIn {
            NotifyService.communityNewPost(app: req.application, postID: post.id, communityID: communityID,
                                           authorID: req.userID, logger: req.logger)
        }
        return try await ConnectionsController.encode(DataResponse(data: post), req, .created)
    }

    /// GET /api/listings/:id, the listing's post, as the viewer may see it.
    static func get(_ req: Request) async throws -> DataResponse<PostObject> {
        let db = req.db.sql()
        guard let id = req.parameters.get("id"), UUID(uuidString: id) != nil,
              let owner = try await ListingStore.owner(listingID: id, on: db),
              let post = try await PostStore.findById(owner.post_id, viewer: req.userID, on: db) else {
            throw Abort(.notFound, reason: "Listing not found")
        }
        return DataResponse(data: post)
    }

    /// PATCH /api/listings/:id, the seller's edits, including marking it sold.
    static func update(_ req: Request) async throws -> DataResponse<PostObject> {
        let db = req.db.sql()
        guard let id = req.parameters.get("id"), UUID(uuidString: id) != nil,
              let owner = try await ListingStore.owner(listingID: id, on: db) else {
            throw Abort(.notFound, reason: "Listing not found")
        }
        guard owner.author_id == req.userID else { throw Abort(.forbidden, reason: "Only the seller can edit this listing") }
        let patch = try req.content.decode(ListingStore.Patch.self)
        try ModerationGate.check([patch.title, patch.content, patch.location, patch.auto_reply]
                                 + (patch.items ?? []).map(\.title), .text)
        let descriptionChanged = try await ListingStore.update(listingID: id, patch, on: req.db)
        var liveIn: [String] = []
        if let communityIDs = patch.community_ids {
            liveIn = try await ListingStore.setCommunities(listingID: id, communityIDs, seller: req.userID, on: req.db)
        }
        guard let post = try await PostStore.findById(owner.post_id, viewer: req.userID, includeOwnUnpublished: true, on: db) else {
            throw Abort(.notFound, reason: "Listing not found")
        }
        if descriptionChanged {
            await BackgroundJobs.refreshPostAfterContentEdit(req, postID: post.id, content: post.content ?? "")
            await TranslationService.enqueue(req, .post, id: post.id)
            await ModerationScan.enqueue(req, .post, id: post.id)
        }
        for communityID in liveIn {
            NotifyService.communityNewPost(app: req.application, postID: post.id, communityID: communityID,
                                           authorID: req.userID, logger: req.logger)
        }
        return DataResponse(data: post)
    }

    struct ItemStatusBody: Content { var status: String }

    /// PATCH /api/listings/:id/items/:itemId, the seller marks one item sold
    /// or for sale again. The listing is sold once every item is.
    static func updateItem(_ req: Request) async throws -> DataResponse<PostObject> {
        let db = req.db.sql()
        guard let id = req.parameters.get("id"), UUID(uuidString: id) != nil,
              let itemID = req.parameters.get("itemId"), UUID(uuidString: itemID) != nil,
              let owner = try await ListingStore.owner(listingID: id, on: db) else {
            throw Abort(.notFound, reason: "Listing not found")
        }
        guard owner.author_id == req.userID else { throw Abort(.forbidden, reason: "Only the seller can edit this listing") }
        let body = try req.content.decode(ItemStatusBody.self)
        try await ListingStore.setItemStatus(listingID: id, itemID: itemID, status: body.status, on: req.db)
        guard let post = try await PostStore.findById(owner.post_id, viewer: req.userID, includeOwnUnpublished: true, on: db) else {
            throw Abort(.notFound, reason: "Listing not found")
        }
        return DataResponse(data: post)
    }

    /// POST /api/listings/:id/items/:itemId/ask, a buyer is about to ask the
    /// seller about one item (the app then sends the message). Allowed once
    /// every 20 minutes per buyer and item, so the seller isn't flooded.
    struct AskResult: Content { var asked = true }

    static func askAboutItem(_ req: Request) async throws -> AskResult {
        let db = req.db.sql()
        guard let id = req.parameters.get("id"), UUID(uuidString: id) != nil,
              let itemID = req.parameters.get("itemId"), UUID(uuidString: itemID) != nil,
              let owner = try await ListingStore.owner(listingID: id, on: db),
              try await !PostStore.findVisible([owner.post_id], viewer: req.userID, on: db).isEmpty else {
            throw Abort(.notFound, reason: "Listing not found")
        }
        guard owner.author_id != req.userID else { throw Abort(.forbidden, reason: "This is your own listing") }
        try await ListingStore.claimItemAsk(listingID: id, itemID: itemID, buyer: req.userID, on: db)
        return AskResult()
    }

    /// POST /api/listings/:id/reup, the seller posts the item again as new.
    static func reup(_ req: Request) async throws -> DataResponse<PostObject> {
        guard let id = req.parameters.get("id"), UUID(uuidString: id) != nil else {
            throw Abort(.notFound, reason: "Listing not found")
        }
        let postID = try await ListingStore.reup(listingID: id, seller: req.userID, on: req.db)
        await TranslationService.enqueue(req, .post, id: postID)
        guard let post = try await PostStore.findById(postID, viewer: req.userID, on: req.db.sql()) else {
            throw Abort(.internalServerError)
        }
        return DataResponse(data: post)
    }
}

import Vapor
import SQLKit

/// The Marketplace tab and a listing's own page. A listing is a community
/// post (migration 072), so it's created through `POST /communities/:id/posts`
/// and deleted like any post; this covers browsing and the seller's edits.
struct MarketplaceController {
    static func register(routes: any RoutesBuilder) {
        let m = routes.grouped("marketplace").grouped(AuthMiddleware())
        m.get(use: list)
        // Check legit (migration 133), Hobby only for now.
        m.get("sellers", ":id", "legit", use: legitSummary)
        m.get("legit-invites", ":id", use: legitCard)
        m.post("legit-invites", ":id", "review", use: reviewLegitCard)
        // Seller profile and seller follows (migration 135), Hobby only for now.
        m.get("sellers", ":id", "profile", use: sellerProfile)
        m.patch("profile", use: updateSellerProfile)
        m.post("sellers", ":id", "follow", use: followSeller)
        m.delete("sellers", ":id", "follow", use: unfollowSeller)
        let l = routes.grouped("listings").grouped(AuthMiddleware())
        l.post(use: create)
        l.get(":id", use: get)
        l.patch(":id", use: update)
        l.post(":id", "reup", use: reup)
        // Deposits and sales confirmed from them (migration 139).
        l.put(":id", "items", ":itemId", "deposit", use: setDeposit)
        l.post(":id", "sales", use: confirmSale)
        l.post(":id", "items", ":itemId", "ask", use: askAboutItem)
    }

    /// GET /api/marketplace?mode=&q=&community_id=&seller_id=&limit=&offset=
    /// With `seller_id`: that seller's items, sold ones too (after the rest).
    /// `community_ids` / `exclude_community_ids` (comma-separated, up to 10):
    /// only items listed in, or not listed in, any of those communities.
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
        let inCommunities = try communityIDs(req, "community_ids")
        let outsideCommunities = try communityIDs(req, "exclude_community_ids")
        let limit = PostsController.clamp(try? req.query.get(Int.self, at: "limit"), 30, 1, 50)
        let offset = req.pageOffset
        return DataListResponse(data: try await ListingStore.marketplace(
            viewer: req.userID, mode: mode, query: q, communityID: communityID, sellerID: sellerID,
            inCommunities: inCommunities, outsideCommunities: outsideCommunities,
            limit: limit, offset: offset, on: req.db.sql()))
    }

    private static func communityIDs(_ req: Request, _ key: String) throws -> [String]? {
        guard let raw = (try? req.query.get(String.self, at: key))?.nilIfEmpty else { return nil }
        let ids = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        guard ids.count <= 10, ids.allSatisfy({ UUID(uuidString: $0) != nil }) else {
            throw Abort(.badRequest, reason: "Invalid communities")
        }
        return ids
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
        // Only a brand-new listing, never a re-up, so followers aren't spammed.
        if post.status == nil || post.status == "posted" {
            NotifyService.sellerListed(app: req.application, postID: post.id, sellerID: req.userID, mode: mode,
                                       title: b.listingData?.title ?? b.listingData?.items?.first?.title,
                                       logger: req.logger)
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

    /// The listing for the seller's deposit or sale: it must be theirs and in Hobby.
    private static func ownListing(_ req: Request) async throws -> (id: String, postID: String) {
        guard let id = req.parameters.get("id")?.lowercased(), UUID(uuidString: id) != nil,
              let owner = try await ListingStore.owner(listingID: id, on: req.db.sql()) else {
            throw Abort(.notFound, reason: "Listing not found")
        }
        guard owner.author_id == req.userID else { throw Abort(.forbidden, reason: "Only the seller can do this") }
        guard let post = try await PostStore.findById(owner.post_id, viewer: req.userID, includeOwnUnpublished: true,
                                                      on: req.db.sql()) else {
            throw Abort(.notFound, reason: "Listing not found")
        }
        try requireHobby(post.mode)
        return (id, owner.post_id)
    }

    private static func listingPost(_ postID: String, _ req: Request) async throws -> DataResponse<PostObject> {
        guard let post = try await PostStore.findById(postID, viewer: req.userID, includeOwnUnpublished: true,
                                                      on: req.db.sql()) else {
            throw Abort(.notFound, reason: "Listing not found")
        }
        return DataResponse(data: post)
    }

    struct DepositBody: Content { var conversation_id: String; var quantity: Int }

    /// PUT /api/listings/:id/items/:itemId/deposit, sets how many units the
    /// buyer in that chat has put a deposit on (0 clears it). Those units come
    /// off what others can buy until the seller confirms them as sold.
    static func setDeposit(_ req: Request) async throws -> DataResponse<PostObject> {
        let listing = try await ownListing(req)
        guard let itemID = req.parameters.get("itemId")?.lowercased(), UUID(uuidString: itemID) != nil else {
            throw Abort(.notFound, reason: "Item not found")
        }
        let b = try req.content.decode(DepositBody.self)
        let buyer = try await buyerFromConversation(b.conversation_id, req)
        try await ListingStore.setDeposit(listingID: listing.id, itemID: itemID, buyer: buyer,
                                          conversationID: b.conversation_id.lowercased(), quantity: b.quantity, on: req.db)
        return try await listingPost(listing.postID, req)
    }

    struct SaleBody: Content { var buyer_id: String; var item_id: String?; var all: Bool? }

    /// POST /api/listings/:id/sales, the seller confirms a buyer's deposit as
    /// sold (one item, or `all` of that buyer's deposits in the listing) once it
    /// has been delivered. Each item sold sends the buyer a review card.
    static func confirmSale(_ req: Request) async throws -> DataResponse<PostObject> {
        let listing = try await ownListing(req)
        let b = try req.content.decode(SaleBody.self)
        let buyer = b.buyer_id.lowercased()
        guard UUID(uuidString: buyer) != nil else { throw Abort(.badRequest, reason: "Pick the buyer") }
        let itemID = b.item_id?.lowercased()
        if b.all != true {
            guard let itemID, UUID(uuidString: itemID) != nil else { throw Abort(.badRequest, reason: "Pick the item") }
        }
        let sold = try await ListingStore.confirmDeposits(listingID: listing.id, itemID: b.all == true ? nil : itemID,
                                                          buyer: buyer, on: req.db)
        for sale in sold {
            try await sendCard(conversationID: sale.conversation_id, buyer: buyer, listingID: listing.id, sale: sale, req)
        }
        return try await listingPost(listing.postID, req)
    }

    /// The other person in the seller's 1-on-1 Hobby chat, who must be able to
    /// receive a message from them (not blocked, not past the request limit).
    private static func buyerFromConversation(_ raw: String, _ req: Request) async throws -> String {
        let db = req.db.sql()
        let conversationID = raw.lowercased()
        guard UUID(uuidString: conversationID) != nil,
              let conv = try await ChatStore.conversationByID(conversationID, on: db), !conv.is_group,
              try await ChatStore.isParticipant(conversationID, req.userID, on: db) else {
            throw Abort(.notFound, reason: "Conversation not found")
        }
        try requireHobby(conv.mode)
        let parts = try await ChatStore.participants(conversationID, on: db)
        guard parts.count == 2, let buyer = parts.first(where: { $0 != req.userID }) else {
            throw Abort(.badRequest, reason: "Pick a chat with one buyer")
        }
        try await MessagesController.assertNotBlockedInConversation(conversationID, req.userID, on: db)
        switch try await MessageRequests.gate(conversationID: conversationID, senderID: req.userID, on: db) {
        case .limitReached: throw Abort(.forbidden, reason: MessageRequests.limitReason)
        case .restricted: throw Abort(.forbidden, reason: MessageRequests.restrictedReason)
        case .open: break
        }
        return buyer
    }

    /// Sends the buyer a review card for what they bought, as a chat message.
    /// Name, price and photo come from the item itself, never from the client.
    private static func sendCard(conversationID: String, buyer: String, listingID: String,
                                 sale: ListingStore.ConfirmedSale, _ req: Request) async throws {
        let db = req.db.sql()
        _ = try await LegitStore.ensurePost(seller: req.userID, mode: "hobby", on: db)
        let inviteID = try await LegitStore.createInvite(seller: req.userID, buyer: buyer, mode: "hobby",
            listingID: listingID, itemID: sale.item_id, title: sale.title, imageURL: sale.image, price: sale.price,
            quantity: sale.quantity, on: db)
        let messageID = try await ChatStore.insertMessage(conversationID, senderID: req.userID, content: nil,
            messageType: "legit_check", mediaUrl: nil, replyToMessageID: nil, voiceDuration: nil, voiceWaveform: nil,
            legitInviteID: inviteID, on: db)
        guard let msg = try await ChatStore.messageByID(messageID, on: db) else { throw Abort(.internalServerError) }
        let parts = try await ChatStore.participants(conversationID, on: db)
        req.socketHub.emitConversation(conversationID, participants: parts, event: "new_message", msg)
        let uid = req.userID
        NotifyService.fireAndForget(req) { d, h, l in
            await NotifyService.notifyNewMessage(conversationID: conversationID, senderID: uid, message: msg, on: d, hub: h, logger: l)
        }
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

    // MARK: seller profile

    private static func sellerID(_ req: Request) async throws -> String {
        guard let seller = req.parameters.get("id")?.lowercased(), UUID(uuidString: seller) != nil,
              try await UserStore.findById(seller, mode: "hobby", on: req.db.sql()) != nil else {
            throw Abort(.notFound, reason: "Seller not found")
        }
        return seller
    }

    private static func requireMarketplaceHobby(_ mode: String?) throws {
        guard mode == "hobby" else { throw Abort(.badRequest, reason: "The Marketplace is in Hobby mode only") }
    }

    /// GET /api/marketplace/sellers/:id/profile?mode=hobby
    static func sellerProfile(_ req: Request) async throws -> DataResponse<SellerProfileStore.Profile> {
        try requireMarketplaceHobby(try? req.query.get(String.self, at: "mode"))
        let seller = try await sellerID(req)
        guard try await !UserStore.isBlockedEitherWay(req.userID, seller, on: req.db.sql()),
              let profile = try await SellerProfileStore.get(seller: seller, mode: "hobby", viewer: req.userID,
                                                             on: req.db.sql()) else {
            throw Abort(.notFound, reason: "Seller not found")
        }
        return DataResponse(data: profile)
    }

    struct SellerProfileBody: Content {
        var mode: String?
        var display_name: String?
        var avatar_url: String?
        var cover_url: String?
        var bio: String?
    }

    /// PATCH /api/marketplace/profile, the seller's own Marketplace identity.
    /// Sends every field; an empty one goes back to the normal profile's.
    static func updateSellerProfile(_ req: Request) async throws -> DataResponse<SellerProfileStore.Profile> {
        let b = try req.content.decode(SellerProfileBody.self)
        try requireMarketplaceHobby(b.mode)
        try req.requireNotBanned(in: "hobby")
        try req.requireNotRestricted(in: "hobby")
        let name = b.display_name?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let bio = b.bio?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        if let name, name.count > SellerProfileStore.maxNameLength {
            throw Abort(.badRequest, reason: "Name must be \(SellerProfileStore.maxNameLength) characters or fewer")
        }
        if let bio, bio.count > SellerProfileStore.maxBioLength {
            throw Abort(.badRequest, reason: "Bio must be \(SellerProfileStore.maxBioLength) characters or fewer")
        }
        try ModerationGate.check([name, bio], .text)
        let fields = SellerProfileStore.Fields(
            displayName: name, avatarURL: try MediaPath.uploaded(b.avatar_url?.nilIfEmpty),
            coverURL: try MediaPath.uploaded(b.cover_url?.nilIfEmpty), bio: bio)
        let db = req.db.sql()
        try await SellerProfileStore.save(seller: req.userID, mode: "hobby", fields, on: db)
        guard let profile = try await SellerProfileStore.get(seller: req.userID, mode: "hobby", viewer: req.userID,
                                                             on: db) else { throw Abort(.internalServerError) }
        return DataResponse(data: profile)
    }

    struct SellerFollowState: Content { var is_following: Bool; var follower_count: Int }

    /// POST /api/marketplace/sellers/:id/follow?mode=hobby
    static func followSeller(_ req: Request) async throws -> DataResponse<SellerFollowState> {
        try requireMarketplaceHobby(try? req.query.get(String.self, at: "mode"))
        let seller = try await sellerID(req)
        guard seller != req.userID else { throw Abort(.badRequest, reason: "You can't follow yourself") }
        let db = req.db.sql()
        guard try await !UserStore.isBlockedEitherWay(req.userID, seller, on: db) else {
            throw Abort(.forbidden, reason: "Can't follow this seller")
        }
        try await AccountBans.refuseIfBanned(seller, mode: "hobby", on: db)
        try await SellerProfileStore.follow(req.userID, seller: seller, mode: "hobby", on: db)
        return try await followState(seller, req)
    }

    /// DELETE /api/marketplace/sellers/:id/follow?mode=hobby
    static func unfollowSeller(_ req: Request) async throws -> DataResponse<SellerFollowState> {
        try requireMarketplaceHobby(try? req.query.get(String.self, at: "mode"))
        let seller = try await sellerID(req)
        try await SellerProfileStore.unfollow(req.userID, seller: seller, mode: "hobby", on: req.db.sql())
        return try await followState(seller, req)
    }

    private static func followState(_ seller: String, _ req: Request) async throws -> DataResponse<SellerFollowState> {
        guard let p = try await SellerProfileStore.get(seller: seller, mode: "hobby", viewer: req.userID,
                                                       on: req.db.sql()) else { throw Abort(.notFound) }
        return DataResponse(data: SellerFollowState(is_following: p.is_following, follower_count: p.follower_count))
    }

    // MARK: check legit

    /// Communities and the Marketplace are Hobby-only for now (KNOWN_GAPS.md).
    private static func requireHobby(_ mode: String?) throws {
        guard mode == "hobby" else { throw Abort(.badRequest, reason: "Reviews are in Hobby mode only") }
    }

    /// GET /api/marketplace/sellers/:id/legit?mode=hobby, the seller's
    /// check-legit post with its rating and badge.
    static func legitSummary(_ req: Request) async throws -> DataResponse<LegitStore.Summary> {
        let mode = try? req.query.get(String.self, at: "mode")
        try requireHobby(mode)
        guard let seller = req.parameters.get("id")?.lowercased(), UUID(uuidString: seller) != nil,
              try await UserStore.findById(seller, mode: "hobby", on: req.db.sql()) != nil else {
            throw Abort(.notFound, reason: "Seller not found")
        }
        return DataResponse(data: try await LegitStore.summary(seller: seller, mode: "hobby", viewer: req.userID,
                                                               on: req.db.sql()))
    }

    /// GET /api/marketplace/legit-invites/:id, the card as its seller or buyer sees it.
    static func legitCard(_ req: Request) async throws -> DataResponse<LegitStore.Invite> {
        guard let id = req.parameters.get("id"), UUID(uuidString: id) != nil,
              let invite = try await LegitStore.invite(id, viewer: req.userID, on: req.db.sql()) else {
            throw Abort(.notFound, reason: "Review card not found")
        }
        return DataResponse(data: invite)
    }

    struct LegitReviewBody: Content { var rating: Int; var comment: String }

    /// POST /api/marketplace/legit-invites/:id/review, the buyer's stars and
    /// comment, once per card and within its 3 days.
    static func reviewLegitCard(_ req: Request) async throws -> DataResponse<LegitStore.Invite> {
        guard let id = req.parameters.get("id"), UUID(uuidString: id) != nil else {
            throw Abort(.notFound, reason: "Review card not found")
        }
        try req.requireRoom(for: .comment)
        let b = try req.content.decode(LegitReviewBody.self)
        let text = b.comment.trimmedText
        guard !text.isEmpty else { throw Abort(.badRequest, reason: "Write a few words about your purchase") }
        try InteractionsController.validateCommentLength(text)
        try ModerationGate.check([text], .text)
        let done = try await LegitStore.review(inviteID: id, buyer: req.userID, rating: b.rating, text: text, on: req.db)
        NotifyService.dispatchSocial(req, .init(
            type: "post_commented", actorID: req.userID, recipientID: done.sellerID,
            postID: done.postID, commentID: done.commentID))
        await TranslationService.enqueue(req, .comment, id: done.commentID)
        await ModerationScan.enqueue(req, .comment, id: done.commentID)
        guard let invite = try await LegitStore.invite(id, viewer: req.userID, on: req.db.sql()) else {
            throw Abort(.internalServerError)
        }
        return DataResponse(data: invite)
    }
}

import Foundation

/// Marketplace listings. A listing is a community post, so these come back
/// as `Post`s with `listingData`; creating one goes through the composer and
/// deleting one is an ordinary post delete.
struct MarketplaceRepository {
    private let client = NetworkClient.shared

    /// Available listings in your communities, in `mode`, newest first.
    /// `sellerId`: just that seller's items, sold ones included (after the rest).
    /// `inCommunities` / `outsideCommunities`: only items listed in, or not
    /// listed in, any of these communities (a seller page's two sections).
    func listings(mode: AppMode, query: String, communityId: String?, sellerId: String? = nil,
                  inCommunities: [String]? = nil, outsideCommunities: [String]? = nil,
                  offset: Int, token: String) async throws -> [Post] {
        var items: [URLQueryItem] = [
            .init(name: "mode", value: mode.rawValue),
            .init(name: "limit", value: "30"),
            .init(name: "offset", value: "\(offset)"),
        ]
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty { items.append(.init(name: "q", value: q)) }
        if let communityId { items.append(.init(name: "community_id", value: communityId)) }
        if let sellerId { items.append(.init(name: "seller_id", value: sellerId)) }
        if let inCommunities { items.append(.init(name: "community_ids", value: inCommunities.joined(separator: ","))) }
        if let outsideCommunities, !outsideCommunities.isEmpty {
            items.append(.init(name: "exclude_community_ids", value: outsideCommunities.joined(separator: ",")))
        }
        let res = try await client.fetch(DataListResponse<PostDTO>.self, path: "/marketplace", token: token, queryItems: items)
        return res.data.map { $0.toPost() }
    }

    /// A new listing in the Marketplace, also listed in `community_ids` (up to 5).
    func create(fields: [String: Any], token: String) async throws -> Post {
        var fields = fields
        fields["content_format"] = PostRepository.contentFormat
        let body = try JSONSerialization.data(withJSONObject: fields)
        return try await client.fetch(DataResponse<PostDTO>.self, path: "/listings", method: "POST",
                                      token: token, bodyData: body).data.toPost()
    }

    func listing(id: String, token: String) async throws -> Post {
        try await client.fetch(DataResponse<PostDTO>.self, path: "/listings/\(id)", token: token).data.toPost()
    }

    /// The seller's edits; only the keys given change. An empty location or
    /// auto-reply clears it.
    func update(id: String, fields: [String: Any], token: String) async throws -> Post {
        let body = try JSONSerialization.data(withJSONObject: fields)
        return try await client.fetch(DataResponse<PostDTO>.self, path: "/listings/\(id)", method: "PATCH",
                                      token: token, bodyData: body).data.toPost()
    }

    /// Sets how many units of an item are on deposit for the buyer in that
    /// chat (0 clears it); the listing's post.
    func setDeposit(listingId: String, itemId: String, conversationId: String, quantity: Int,
                    token: String) async throws -> Post {
        let body = try JSONSerialization.data(withJSONObject: ["conversation_id": conversationId, "quantity": quantity])
        return try await client.fetch(DataResponse<PostDTO>.self, path: "/listings/\(listingId)/items/\(itemId)/deposit",
                                      method: "PUT", token: token, bodyData: body).data.toPost()
    }

    /// Confirms the buyers' deposits as sold, on one item or (`itemId` nil) all
    /// of theirs in the listing; each sends its buyer a review card. The post.
    func confirmSale(listingId: String, itemId: String?, buyerIds: [String], token: String) async throws -> Post {
        var fields: [String: Any] = ["buyer_ids": buyerIds]
        if let itemId { fields["item_id"] = itemId } else { fields["all"] = true }
        let body = try JSONSerialization.data(withJSONObject: fields)
        return try await client.fetch(DataResponse<PostDTO>.self, path: "/listings/\(listingId)/sales",
                                      method: "POST", token: token, bodyData: body).data.toPost()
    }

    /// Tells the server the buyer is asking about one item; refused (429) when
    /// they already did in the last 20 minutes.
    func askAboutItem(listingId: String, itemId: String, token: String) async throws {
        struct Asked: Decodable { let asked: Bool }
        _ = try await client.fetch(Asked.self, path: "/listings/\(listingId)/items/\(itemId)/ask", method: "POST", token: token)
    }

    /// Posts the item again as new; the new post (the old one is retired).
    func reup(id: String, token: String) async throws -> Post {
        try await client.fetch(DataResponse<PostDTO>.self, path: "/listings/\(id)/reup", method: "POST", token: token).data.toPost()
    }

    // MARK: check legit (Hobby only for now)

    /// The seller's check-legit post, rating and badge.
    func legitSummary(sellerId: String, token: String) async throws -> LegitSummary {
        let items: [URLQueryItem] = [.init(name: "mode", value: AppMode.hobby.rawValue)]
        return try await client.fetch(DataResponse<LegitSummaryDTO>.self, path: "/marketplace/sellers/\(sellerId)/legit",
                                      token: token, queryItems: items).data.toModel()
    }

    func legitCard(id: String, token: String) async throws -> LegitCard {
        try await client.fetch(DataResponse<LegitCardDTO>.self, path: "/marketplace/legit-invites/\(id)",
                               token: token).data.toModel()
    }

    // MARK: seller profile (Hobby only for now)

    func sellerProfile(sellerId: String, token: String) async throws -> SellerProfile {
        try await client.fetch(DataResponse<SellerProfile>.self, path: "/marketplace/sellers/\(sellerId)/profile",
                               token: token, queryItems: [.init(name: "mode", value: AppMode.hobby.rawValue)]).data
    }

    /// Saves every field; an empty one goes back to the normal profile's.
    func updateSellerProfile(name: String, bio: String, avatarUrl: String?, coverUrl: String?,
                             token: String) async throws -> SellerProfile {
        let body: [String: Any] = ["mode": AppMode.hobby.rawValue, "display_name": name, "bio": bio,
                                   "avatar_url": avatarUrl ?? "", "cover_url": coverUrl ?? ""]
        return try await client.fetch(DataResponse<SellerProfile>.self, path: "/marketplace/profile", method: "PATCH",
                                      token: token, bodyData: try JSONSerialization.data(withJSONObject: body)).data
    }

    func setFollowingSeller(_ follow: Bool, sellerId: String, token: String) async throws -> SellerFollowState {
        try await client.fetch(DataResponse<SellerFollowState>.self, path: "/marketplace/sellers/\(sellerId)/follow",
                               method: follow ? "POST" : "DELETE", token: token,
                               queryItems: [.init(name: "mode", value: AppMode.hobby.rawValue)]).data
    }

    func reviewLegitCard(id: String, rating: Int, comment: String, token: String) async throws -> LegitCard {
        let body = try JSONSerialization.data(withJSONObject: ["rating": rating, "comment": comment])
        return try await client.fetch(DataResponse<LegitCardDTO>.self, path: "/marketplace/legit-invites/\(id)/review",
                                      method: "POST", token: token, bodyData: body).data.toModel()
    }
}

// MARK: - Check legit models

/// A seller's check-legit post (only in the Marketplace) and their rating.
struct LegitSummary {
    /// nil when the seller hid it.
    var post: Post?
    var ratingAverage: Double?
    var ratingCount: Int
    var isLegit: Bool
}

/// A legit card a seller sent a buyer: one review, within 3 days.
struct LegitCard: Equatable {
    enum State: String { case open, reviewed, expired }
    let id: String
    let sellerId: String
    let buyerId: String
    let itemTitle: String
    let itemImageUrl: String?
    /// Whole VND; nil on cards sent before prices were shown.
    let itemPrice: Int64?
    /// How many they bought (migration 139).
    let itemQuantity: Int
    let expiresAt: Date
    let rating: Int?
    let state: State
}

/// A seller's Marketplace identity: what everyone sees (falls back to their
/// normal profile) and what they set themselves (`own…`, nil = not set).
struct SellerProfile: Decodable, Equatable {
    let userId: String
    let username: String
    let displayName: String
    let avatarUrl: String?
    let coverUrl: String?
    let bio: String?
    let avatarColor: String?
    let ownDisplayName: String?
    let ownAvatarUrl: String?
    let ownCoverUrl: String?
    let ownBio: String?
    /// The normal profile's photo and cover: what an unset one falls back to.
    let profileAvatarUrl: String?
    let profileCoverUrl: String?
    var followerCount: Int
    var isFollowing: Bool
    enum CodingKeys: String, CodingKey {
        case username, bio
        case userId = "user_id", displayName = "display_name", avatarUrl = "avatar_url", coverUrl = "cover_url"
        case avatarColor = "avatar_color", ownDisplayName = "own_display_name", ownAvatarUrl = "own_avatar_url"
        case ownCoverUrl = "own_cover_url", ownBio = "own_bio", followerCount = "follower_count"
        case profileAvatarUrl = "profile_avatar_url", profileCoverUrl = "profile_cover_url"
        case isFollowing = "is_following"
    }
}

struct SellerFollowState: Decodable {
    let isFollowing: Bool
    let followerCount: Int
    enum CodingKeys: String, CodingKey { case isFollowing = "is_following", followerCount = "follower_count" }
}

struct LegitSummaryDTO: Decodable {
    let post: PostDTO?
    let ratingAvg: Double?
    let ratingCount: Int
    let isLegit: Bool
    enum CodingKeys: String, CodingKey {
        case post, ratingAvg = "rating_avg", ratingCount = "rating_count", isLegit = "is_legit"
    }
    func toModel() -> LegitSummary {
        LegitSummary(post: post?.toPost(), ratingAverage: ratingAvg, ratingCount: ratingCount, isLegit: isLegit)
    }
}

struct LegitCardDTO: Decodable {
    let id: String
    let sellerId: String
    let buyerId: String
    let itemTitle: String
    let itemImageUrl: String?
    let itemPrice: Int64?
    let itemQuantity: Int?
    let expiresAt: Date
    let rating: Int?
    let state: String
    enum CodingKeys: String, CodingKey {
        case id, rating, state, sellerId = "seller_id", buyerId = "buyer_id", itemTitle = "item_title",
             itemImageUrl = "item_image_url", itemPrice = "item_price", itemQuantity = "item_quantity",
             expiresAt = "expires_at"
    }
    func toModel() -> LegitCard {
        LegitCard(id: id, sellerId: sellerId.lowercased(), buyerId: buyerId.lowercased(), itemTitle: itemTitle,
                  itemImageUrl: itemImageUrl, itemPrice: itemPrice, itemQuantity: itemQuantity ?? 1, expiresAt: expiresAt, rating: rating,
                  state: LegitCard.State(rawValue: state) ?? .expired)
    }
}

/// A response whose body the caller doesn't need.
private struct IgnoredPayload: Decodable {}

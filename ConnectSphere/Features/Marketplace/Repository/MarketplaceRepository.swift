import Foundation

/// Marketplace listings. A listing is a community post, so these come back
/// as `Post`s with `listingData`; creating one goes through the composer and
/// deleting one is an ordinary post delete.
struct MarketplaceRepository {
    private let client = NetworkClient.shared

    /// Available listings in your communities, in `mode`, newest first.
    /// `sellerId`: just that seller's items, sold ones included (after the rest).
    func listings(mode: AppMode, query: String, communityId: String?, sellerId: String? = nil,
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

    /// Posts the item again as new; the new post (the old one is retired).
    func reup(id: String, token: String) async throws -> Post {
        try await client.fetch(DataResponse<PostDTO>.self, path: "/listings/\(id)/reup", method: "POST", token: token).data.toPost()
    }
}

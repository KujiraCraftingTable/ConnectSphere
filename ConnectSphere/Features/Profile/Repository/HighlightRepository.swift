import Foundation

/// Highlights (`/users/:id/highlights`). HTTP + decoding only; every write
/// returns the owner's whole updated list.
struct HighlightRepository {
    private let client = NetworkClient.shared

    private func body(_ dict: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: dict) }
    private func photos(_ imageUrls: [String], _ storyIds: [String]) -> [String: Any] {
        ["image_urls": imageUrls, "story_ids": storyIds]
    }

    func list(of userId: String, token: String) async throws -> [Highlight] {
        try await client.fetch(DataListResponse<Highlight>.self, path: "/users/\(userId)/highlights", token: token).data
    }

    func create(title: String, imageUrls: [String], storyIds: [String], token: String) async throws -> [Highlight] {
        var dict = photos(imageUrls, storyIds)
        dict["title"] = title
        return try await client.fetch(DataListResponse<Highlight>.self, path: "/users/me/highlights", method: "POST",
                                      token: token, bodyData: try body(dict)).data
    }

    func addItems(to id: String, imageUrls: [String], storyIds: [String], token: String) async throws -> [Highlight] {
        try await client.fetch(DataListResponse<Highlight>.self, path: "/users/me/highlights/\(id)/items", method: "POST",
                               token: token, bodyData: try body(photos(imageUrls, storyIds))).data
    }

    func rename(_ id: String, title: String, token: String) async throws -> [Highlight] {
        try await client.fetch(DataListResponse<Highlight>.self, path: "/users/me/highlights/\(id)", method: "PATCH",
                               token: token, bodyData: try body(["title": title])).data
    }

    func setCover(_ id: String, imageUrl: String, token: String) async throws -> [Highlight] {
        try await client.fetch(DataListResponse<Highlight>.self, path: "/users/me/highlights/\(id)", method: "PATCH",
                               token: token, bodyData: try body(["cover_url": imageUrl])).data
    }

    func removeItem(_ itemId: String, from id: String, token: String) async throws -> [Highlight] {
        try await client.fetch(DataListResponse<Highlight>.self, path: "/users/me/highlights/\(id)/items/\(itemId)",
                               method: "DELETE", token: token).data
    }

    func delete(_ id: String, token: String) async throws -> [Highlight] {
        try await client.fetch(DataListResponse<Highlight>.self, path: "/users/me/highlights/\(id)", method: "DELETE",
                               token: token).data
    }
}

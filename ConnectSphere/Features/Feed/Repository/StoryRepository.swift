import Foundation

/// API calls for 24h stories.
struct StoryRepository {
    private let client = NetworkClient.shared

    private struct ListResponse: Decodable { let data: [StoryDTO] }
    private struct OkResponse: Decodable { let status: String? }

    private func token() throws -> String {
        guard let token = KeychainHelper.load(forKey: KeychainHelper.tokenKey) else {
            throw APIError.serverError(statusCode: 401, message: "Not authenticated")
        }
        return token
    }

    /// The current user's own stories + connections', not yet expired
    func fetchStories() async throws -> [StoryDTO] {
        let response = try await client.fetch(
            ListResponse.self,
            path: "/stories",
            token: try token()
        )
        return response.data
    }

    /// Posts a new story from an already-uploaded image URL
    func createStory(imageUrl: String) async throws {
        struct CreateResponse: Decodable { struct S: Decodable { let id: String }; let data: S }
        _ = try await client.fetch(
            CreateResponse.self,
            path: "/stories",
            method: "POST",
            token: try token(),
            bodyData: NetworkClient.encode(["image_url": imageUrl])
        )
    }

    /// Marks the story as viewed
    func markViewed(storyId: String) async throws {
        _ = try await client.fetch(
            OkResponse.self,
            path: "/stories/\(storyId)/view",
            method: "POST",
            token: try token()
        )
    }

    /// Deletes one of the current user's own stories (backend checks the author)
    func deleteStory(storyId: String) async throws {
        _ = try await client.fetch(
            OkResponse.self,
            path: "/stories/\(storyId)",
            method: "DELETE",
            token: try token()
        )
    }

    /// List of people who have viewed the story — can only be called for the current user's own story
    func fetchViewers(storyId: String) async throws -> [StoryViewerDTO] {
        struct ViewersResponse: Decodable { let data: [StoryViewerDTO] }
        return try await client.fetch(
            ViewersResponse.self,
            path: "/stories/\(storyId)/viewers",
            token: try token()
        ).data
    }
}

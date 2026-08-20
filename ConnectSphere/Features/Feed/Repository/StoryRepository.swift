import Foundation

/// API calls cho stories 24h.
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

    /// Story của mình + connections, chưa hết hạn
    func fetchStories() async throws -> [StoryDTO] {
        let response = try await client.fetch(
            ListResponse.self,
            path: "/stories",
            token: try token()
        )
        return response.data
    }

    /// Đăng story mới từ URL ảnh đã upload
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

    /// Đánh dấu đã xem
    func markViewed(storyId: String) async throws {
        _ = try await client.fetch(
            OkResponse.self,
            path: "/stories/\(storyId)/view",
            method: "POST",
            token: try token()
        )
    }

    /// Xoá story của mình (backend check author)
    func deleteStory(storyId: String) async throws {
        _ = try await client.fetch(
            OkResponse.self,
            path: "/stories/\(storyId)",
            method: "DELETE",
            token: try token()
        )
    }

    /// Danh sách người đã xem — chỉ gọi được với story của mình
    func fetchViewers(storyId: String) async throws -> [StoryViewerDTO] {
        struct ViewersResponse: Decodable { let data: [StoryViewerDTO] }
        return try await client.fetch(
            ViewersResponse.self,
            path: "/stories/\(storyId)/viewers",
            token: try token()
        ).data
    }
}

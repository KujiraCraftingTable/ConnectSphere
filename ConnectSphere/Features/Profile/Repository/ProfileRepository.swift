import Foundation

/// Single access point for user-profile API calls.
struct ProfileRepository {
    private let client = NetworkClient.shared

    func fetchUser(userId: String) async throws -> UserProfile {
        let response = try await client.fetch(
            SingleResponse<UserDTO>.self,
            from: .getUser(id: userId)
        )
        return response.data.toUserProfile()
    }

    func fetchPosts(authorId: String, limit: Int = 20, offset: Int = 0) async throws -> [Post] {
        let response = try await client.fetch(
            PaginatedResponse<PostDTO>.self,
            from: .listPosts(authorId: authorId, limit: limit, offset: offset)
        )
        return response.data.map { $0.toPost() }
    }

    /// Partial update — field nil sẽ không được gửi lên (JSONEncoder bỏ qua nil),
    /// backend chỉ ghi những field có mặt trong body.
    struct ProfileUpdate: Encodable {
        var display_name: String? = nil
        var bio: String?          = nil
        var location: String?     = nil
        var job_title: String?    = nil
        var company: String?      = nil
        var avatar_url: String?   = nil
        var interests: [String]?  = nil
        var skills: [String]?     = nil
    }

    func updateProfile(_ update: ProfileUpdate) async throws -> UserProfile {
        guard let token = KeychainHelper.load(forKey: KeychainHelper.tokenKey) else {
            throw APIError.serverError(statusCode: 401, message: "Not authenticated")
        }
        let response = try await client.fetch(
            SingleResponse<UserDTO>.self,
            path: "/users/me",
            method: "PATCH",
            token: token,
            bodyData: NetworkClient.encode(update)
        )
        return response.data.toUserProfile()
    }
}

import Foundation

/// Single access point for user-profile API calls.
struct ProfileRepository {
    private let client = NetworkClient.shared

    func fetchUser(userId: String, mode: String? = nil) async throws -> UserProfile {
        let response = try await client.fetch(
            SingleResponse<UserDTO>.self,
            from: .getUser(id: userId, mode: mode)
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
    /// mode = persona đang sửa (display_name/bio/avatar/cover ghi vào persona đó);
    /// không gửi thì backend fallback về default_mode của user.
    struct ProfileUpdate: Encodable {
        var mode: String?         = nil
        var display_name: String? = nil
        var bio: String?          = nil
        var location: String?     = nil
        var dob: String?          = nil
        var dob_visibility: String? = nil
        var job_title: String?    = nil
        var company: String?      = nil
        var avatar_url: String?   = nil
        var cover_url: String?    = nil
        var interests: [String]?  = nil
        var skills: [String]?     = nil
        var email: String?        = nil   // "" = gỡ email khỏi tài khoản
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

    /// Tạo persona cho mode thứ 2 (lần đầu switch sang mode chưa setup).
    /// Work kèm job_title/company/skills; hobby kèm interests. Backend trả 409
    /// nếu persona đã tồn tại (sửa qua updateProfile thay vì tạo lại).
    struct PersonaCreate: Encodable {
        let mode: String
        let display_name: String
        var bio: String?          = nil
        var job_title: String?    = nil
        var company: String?      = nil
        var skills: [String]?     = nil
        var interests: [String]?  = nil
    }

    func createPersona(_ body: PersonaCreate) async throws -> UserProfile {
        guard let token = KeychainHelper.load(forKey: KeychainHelper.tokenKey) else {
            throw APIError.serverError(statusCode: 401, message: "Not authenticated")
        }
        let response = try await client.fetch(
            SingleResponse<UserDTO>.self,
            path: "/users/me/personas",
            method: "POST",
            token: token,
            bodyData: NetworkClient.encode(body)
        )
        return response.data.toUserProfile()
    }

    /// Soft-delete tài khoản của chính mình. Xác nhận bằng mật khẩu,
    /// hoặc confirmation = "DELETE" với tài khoản Google chưa có mật khẩu.
    func deleteAccount(password: String?, confirmation: String?) async throws {
        guard let token = KeychainHelper.load(forKey: KeychainHelper.tokenKey) else {
            throw APIError.serverError(statusCode: 401, message: "Not authenticated")
        }
        struct Body: Encodable {
            let password: String?
            let confirmation: String?
        }
        struct OKResponse: Decodable { let status: String }
        _ = try await client.fetch(
            OKResponse.self,
            path: "/users/me",
            method: "DELETE",
            token: token,
            bodyData: NetworkClient.encode(Body(password: password, confirmation: confirmation))
        )
    }
}

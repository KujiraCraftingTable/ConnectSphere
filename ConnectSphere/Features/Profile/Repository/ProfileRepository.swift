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

    /// mode = server-side filter ("hobby"/"work"), `ProfileViewModel` passes
    /// the active mode so pagination offsets stay correct against one mode's
    /// post count, reloading on mode switch rather than re-filtering client-side.
    func fetchPosts(authorId: String, mode: String? = nil, limit: Int = 20, offset: Int = 0) async throws -> [Post] {
        let response = try await client.fetch(
            PaginatedResponse<PostDTO>.self,
            from: .listPosts(mode: mode, authorId: authorId, limit: limit, offset: offset)
        )
        return response.data.map { $0.toPost() }
    }

    /// Partial update, a nil field is not sent (JSONEncoder skips nils),
    /// so the backend only writes the fields present in the body.
    /// mode = the persona being edited (display_name/bio/avatar/cover are written to that persona);
    /// if omitted, the backend falls back to the user's default_mode.
    struct ProfileUpdate: Encodable {
        var mode: String?         = nil
        var display_name: String? = nil
        var bio: String?          = nil
        /// How `bio` is written ("markdown" or "plain"); always sent with `bio`.
        var bio_format: String?   = nil
        var location: String?     = nil
        var dob: String?          = nil
        var dob_visibility: String? = nil
        var job_title: String?    = nil
        var company: String?      = nil
        var avatar_url: String?   = nil
        var cover_url: String?    = nil
        var interests: [String]?  = nil
        var skills: [String]?     = nil
        /// Hobby-only; "" clears the relationship status.
        var languages: [String]?  = nil
        var relationship_status: String? = nil
    }

    /// Privacy: off = strangers can only follow, not send friend requests.
    func setAllowFriendRequests(_ allow: Bool) async throws {
        guard let token = KeychainHelper.load(forKey: KeychainHelper.tokenKey) else {
            throw APIError.serverError(statusCode: 401, message: "Not authenticated")
        }
        struct Body: Encodable { let allow_friend_requests: Bool }
        _ = try await client.fetch(SingleResponse<UserDTO>.self, path: "/users/me", method: "PATCH", token: token,
                                   bodyData: NetworkClient.encode(Body(allow_friend_requests: allow)))
    }

    /// The "See my other profile" button on this mode's profile.
    func setLinksOtherMode(_ link: Bool, mode: AppMode) async throws {
        guard let token = KeychainHelper.load(forKey: KeychainHelper.tokenKey) else {
            throw APIError.serverError(statusCode: 401, message: "Not authenticated")
        }
        struct Body: Encodable { let mode: String; let links_other_mode: Bool }
        _ = try await client.fetch(SingleResponse<UserDTO>.self, path: "/users/me", method: "PATCH", token: token,
                                   bodyData: NetworkClient.encode(Body(mode: mode.rawValue, links_other_mode: link)))
    }

    /// Lock this mode's profile (non-connections see only name, avatar, cover).
    func setLocked(_ locked: Bool, mode: AppMode) async throws {
        guard let token = KeychainHelper.load(forKey: KeychainHelper.tokenKey) else {
            throw APIError.serverError(statusCode: 401, message: "Not authenticated")
        }
        struct Body: Encodable { let mode: String; let locked: Bool }
        _ = try await client.fetch(SingleResponse<UserDTO>.self, path: "/users/me", method: "PATCH", token: token,
                                   bodyData: NetworkClient.encode(Body(mode: mode.rawValue, locked: locked)))
    }

    func setShowInSuggestions(_ show: Bool) async throws {
        guard let token = KeychainHelper.load(forKey: KeychainHelper.tokenKey) else {
            throw APIError.serverError(statusCode: 401, message: "Not authenticated")
        }
        struct Body: Encodable { let show_in_suggestions: Bool }
        _ = try await client.fetch(SingleResponse<UserDTO>.self, path: "/users/me", method: "PATCH", token: token,
                                   bodyData: NetworkClient.encode(Body(show_in_suggestions: show)))
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

    /// Creates a persona for the second mode (first switch into a mode that hasn't been set up yet).
    /// Work includes job_title/company/skills; hobby includes interests. Backend returns 409
    /// if the persona already exists (edit via updateProfile instead of recreating it).
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

    /// Persists which mode the app should open in after login. Fire-and-forget
    /// from `AppState.requestModeSwitch`, the switch is already reflected
    /// locally, so this is a background sync rather than something the UI
    /// waits on. Separate from `updateProfile`, whose own `mode` field means
    /// "which persona to edit," not "change my default."
    func updateDefaultMode(_ mode: AppMode) async throws {
        guard let token = KeychainHelper.load(forKey: KeychainHelper.tokenKey) else {
            throw APIError.serverError(statusCode: 401, message: "Not authenticated")
        }
        struct Body: Encodable { let mode: String }
        struct OKResponse: Decodable { let status: String }
        _ = try await client.fetch(
            OKResponse.self,
            path: "/users/me/default-mode",
            method: "PATCH",
            token: token,
            bodyData: NetworkClient.encode(Body(mode: mode.rawValue))
        )
    }
}

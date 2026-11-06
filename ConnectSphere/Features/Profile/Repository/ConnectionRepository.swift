import Foundation

/// Trimmed-down user info returned in the connections list
/// (no counters/interests like the full UserDTO).
struct ConnectionUserDTO: Decodable {
    let id: String
    let username: String
    let displayName: String
    let avatarColor: String
    let avatarUrl: String?
    let jobTitle: String?
    let company: String?
    let location: String?

    enum CodingKeys: String, CodingKey {
        case id, username, company, location
        case displayName = "display_name"
        case avatarColor = "avatar_color"
        case avatarUrl   = "avatar_url"
        case jobTitle    = "job_title"
    }

    func toUserProfile() -> UserProfile {
        UserProfile(
            id: id, name: displayName, username: username,
            avatarColor: avatarColor, avatarUrl: avatarUrl, bio: "",
            jobTitle: jobTitle, company: company,
            skills: [], interests: [],
            location: location, gender: nil,
            followerCount: 0, followingCount: 0, postCount: 0,
            score: nil
        )
    }
}

struct ConnectionItemDTO: Decodable, Identifiable {
    let connectionId: String
    let status: String
    let mode: String
    let user: ConnectionUserDTO

    var id: String { connectionId }

    enum CodingKeys: String, CodingKey {
        case status, mode, user
        case connectionId = "connection_id"
    }
}

/// API calls for the connections list plus accepting/declining requests.
struct ConnectionRepository {
    private let client = NetworkClient.shared

    private struct ListResponse: Decodable { let data: [ConnectionItemDTO] }
    private struct StatusOnly: Decodable { let status: String }

    private func token() throws -> String {
        guard let token = KeychainHelper.load(forKey: KeychainHelper.tokenKey) else {
            throw APIError.serverError(statusCode: 401, message: "Not authenticated")
        }
        return token
    }

    /// status: accepted | pending_received | pending_sent
    func fetchConnections(mode: String, status: String) async throws -> [ConnectionItemDTO] {
        let response = try await client.fetch(
            ListResponse.self,
            path: "/connections",
            token: try token(),
            queryItems: [
                URLQueryItem(name: "mode",   value: mode),
                URLQueryItem(name: "status", value: status),
            ]
        )
        return response.data
    }

    func accept(connectionId: String) async throws {
        _ = try await client.fetch(
            StatusOnly.self,
            path: "/connections/accept",
            method: "POST",
            token: try token(),
            bodyData: NetworkClient.encode(["connection_id": connectionId])
        )
    }

    func decline(connectionId: String) async throws {
        _ = try await client.fetch(
            StatusOnly.self,
            path: "/connections/decline",
            method: "POST",
            token: try token(),
            bodyData: NetworkClient.encode(["connection_id": connectionId])
        )
    }

    // MARK: Follows

    private struct FollowState: Decodable { let is_following: Bool }
    private struct PeopleResponse: Decodable { let data: [ConnectionUserDTO] }

    func follow(userId: String, mode: String) async throws {
        _ = try await client.fetch(FollowState.self, path: "/follows/\(userId)", method: "POST", token: try token(),
                                   queryItems: [URLQueryItem(name: "mode", value: mode)])
    }

    func unfollow(userId: String, mode: String) async throws {
        _ = try await client.fetch(FollowState.self, path: "/follows/\(userId)", method: "DELETE", token: try token(),
                                   queryItems: [URLQueryItem(name: "mode", value: mode)])
    }

    /// `followers` or `following` of a user in one mode. Friends excluded.
    func fetchFollows(userId: String, followers: Bool, mode: String) async throws -> [ConnectionUserDTO] {
        try await client.fetch(PeopleResponse.self, path: "/follows/\(userId)", token: try token(),
                               queryItems: [URLQueryItem(name: "type", value: followers ? "followers" : "following"),
                                            URLQueryItem(name: "mode", value: mode)]).data
    }
}

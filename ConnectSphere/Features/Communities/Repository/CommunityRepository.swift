import Foundation

/// Single access point for all community-related API calls.
/// All ViewModels in the Communities feature use this instead of calling NetworkClient directly.
struct CommunityRepository {
    private let client = NetworkClient.shared

    // MARK: - Discovery & Listing

    func fetchCommunities(query: String = "", type: CommunityType? = nil, token: String) async throws -> [Community] {
        var items: [URLQueryItem] = [
            .init(name: "limit",  value: "20"),
            .init(name: "offset", value: "0"),
        ]
        if !query.isEmpty { items.append(.init(name: "query", value: query)) }
        if let type        { items.append(.init(name: "type",  value: type.rawValue)) }

        let res = try await client.fetch(DataListResponse<CommunityDTO>.self,
                                         path: "/communities", token: token, queryItems: items)
        return res.data.map { $0.toCommunity() }
    }

    func fetchMyCommunities(token: String) async throws -> [Community] {
        let res = try await client.fetch(DataListResponse<CommunityDTO>.self,
                                         path: "/communities/me", token: token)
        return res.data.map { $0.toCommunity(isMemberOverride: true) }
    }

    func fetchDetail(communityId: String, token: String) async throws -> Community {
        let res = try await client.fetch(DataResponse<CommunityDTO>.self,
                                         path: "/communities/\(communityId)", token: token)
        return res.data.toCommunity()
    }

    func fetchDiscover(type: CommunityType?, token: String) async throws -> (trending: [Community], recommended: [Community]) {
        var items: [URLQueryItem] = []
        if let type { items.append(.init(name: "type", value: type.rawValue)) }

        let res = try await client.fetch(DataResponse<DiscoverPayload>.self,
                                         path: "/communities/discover", token: token, queryItems: items)
        return (
            trending:    res.data.trending.map    { $0.toCommunity() },
            recommended: res.data.recommended.map { $0.toCommunity() }
        )
    }

    func fetchRecommendations(token: String) async throws -> [Community] {
        let res = try await client.fetch(DataListResponse<CommunityDTO>.self,
                                         path: "/communities/recommendations", token: token,
                                         queryItems: [.init(name: "limit", value: "10")])
        return res.data.map { $0.toCommunity() }
    }

    // MARK: - Membership

    func join(communityId: String, token: String) async throws {
        _ = try await client.fetch(OKResponse.self,
                                    path: "/communities/\(communityId)/join",
                                    method: "POST", token: token)
    }

    func leave(communityId: String, token: String) async throws {
        _ = try await client.fetch(OKResponse.self,
                                    path: "/communities/\(communityId)/leave",
                                    method: "DELETE", token: token)
    }

    /// Returns "joined" or "pending" depending on community privacy.
    func requestToJoin(communityId: String, token: String) async throws -> String {
        let res = try await client.fetch(DataResponse<JoinStatusPayload>.self,
                                          path: "/communities/\(communityId)/request-join",
                                          method: "POST", token: token)
        return res.data.status
    }

    // MARK: - Posts

    func fetchPosts(communityId: String, limit: Int, offset: Int, token: String) async throws -> [CommunityPost] {
        let items: [URLQueryItem] = [
            .init(name: "limit",  value: "\(limit)"),
            .init(name: "offset", value: "\(offset)"),
        ]
        let res = try await client.fetch(DataListResponse<CommunityPostDTO>.self,
                                          path: "/communities/\(communityId)/posts",
                                          token: token, queryItems: items)
        return res.data.map { $0.toCommunityPost() }
    }

    func deletePost(postId: String, token: String) async throws {
        _ = try await client.fetch(OKResponse.self,
                                    path: "/posts/\(postId)",
                                    method: "DELETE", token: token)
    }

    func pinPost(communityId: String, postId: String, token: String) async throws {
        _ = try await client.fetch(OKResponse.self,
                                    path: "/communities/\(communityId)/posts/\(postId)/pin",
                                    method: "POST", token: token)
    }

    func unpinPost(communityId: String, postId: String, token: String) async throws {
        _ = try await client.fetch(OKResponse.self,
                                    path: "/communities/\(communityId)/posts/\(postId)/pin",
                                    method: "DELETE", token: token)
    }

    /// Toggle like on a post. Uses the shared /posts/:id/like route (not a
    /// community-specific one) — works for any post id, including posts inside a community.
    func toggleLikePost(postId: String, token: String) async throws -> (liked: Bool, likeCount: Int) {
        let res = try await client.fetch(LikeResponse.self,
                                          path: "/posts/\(postId)/like",
                                          method: "POST", token: token)
        return (liked: res.liked, likeCount: res.likeCount)
    }

    // MARK: - Members

    func fetchMembers(communityId: String, limit: Int = 50, token: String) async throws -> [CommunityMember] {
        let items: [URLQueryItem] = [
            .init(name: "limit",  value: "\(limit)"),
            .init(name: "offset", value: "0"),
        ]
        let res = try await client.fetch(DataListResponse<CommunityMemberDTO>.self,
                                          path: "/communities/\(communityId)/members",
                                          token: token, queryItems: items)
        return res.data.map { $0.toMember() }
    }

    func kickMember(communityId: String, userId: String, token: String) async throws {
        _ = try await client.fetch(OKResponse.self,
                                    path: "/communities/\(communityId)/members/\(userId)",
                                    method: "DELETE", token: token)
    }

    func updateMemberRole(communityId: String, userId: String, role: MemberRole, token: String) async throws {
        let body = NetworkClient.encode(["role": role.rawValue])
        _ = try await client.fetch(OKResponse.self,
                                    path: "/communities/\(communityId)/members/\(userId)/role",
                                    method: "PATCH", token: token, bodyData: body)
    }

    // MARK: - Admin: Analytics

    func fetchAnalytics(communityId: String, days: Int, token: String) async throws -> CommunityAnalytics {
        let items: [URLQueryItem] = [.init(name: "days", value: "\(days)")]
        let res = try await client.fetch(DataResponse<CommunityAnalytics>.self,
                                          path: "/communities/\(communityId)/analytics",
                                          token: token, queryItems: items)
        return res.data
    }

    // MARK: - Admin: Join Requests

    func fetchJoinRequests(communityId: String, token: String) async throws -> [JoinRequest] {
        let res = try await client.fetch(DataListResponse<JoinRequestDTO>.self,
                                          path: "/communities/\(communityId)/join-requests",
                                          token: token)
        return res.data.map { $0.toJoinRequest() }
    }

    func reviewJoinRequest(communityId: String, requestId: String, status: String, token: String) async throws {
        let body = NetworkClient.encode(["status": status])
        _ = try await client.fetch(DataResponse<EmptyPayload>.self,
                                    path: "/communities/\(communityId)/join-requests/\(requestId)",
                                    method: "PATCH", token: token, bodyData: body)
    }

    // MARK: - Admin: Moderation

    func fetchModerationQueue(communityId: String, status: String, token: String) async throws -> (reports: [ModerationItem], pendingCount: Int) {
        let items: [URLQueryItem] = [
            .init(name: "status", value: status),
            .init(name: "limit",  value: "50"),
            .init(name: "offset", value: "0"),
        ]
        let res = try await client.fetch(DataResponse<ModerationQueueResponse>.self,
                                          path: "/communities/\(communityId)/moderation",
                                          token: token, queryItems: items)
        return (reports: res.data.reports, pendingCount: res.data.pendingCount)
    }

    func resolveReport(communityId: String, reportId: String, action: String, token: String) async throws {
        let body = NetworkClient.encode(["action": action])
        _ = try await client.fetch(OKResponse.self,
                                    path: "/communities/\(communityId)/reports/\(reportId)",
                                    method: "PATCH", token: token, bodyData: body)
    }

    // MARK: - Create Community

    func createCommunity(
        name: String,
        type: String,
        privacy: String,
        iconEmoji: String,
        coverColor: String,
        description: String?,
        token: String
    ) async throws -> Community {
        struct Body: Encodable {
            let name, type, privacy, icon_emoji, cover_color: String
            let description: String?
        }
        let body = NetworkClient.encode(Body(name: name, type: type, privacy: privacy,
                                             icon_emoji: iconEmoji, cover_color: coverColor,
                                             description: description))
        let res = try await client.fetch(DataResponse<CommunityDTO>.self,
                                          path: "/communities", method: "POST",
                                          token: token, bodyData: body)
        return res.data.toCommunity(isMemberOverride: true)
    }

    // MARK: - Reports

    func reportPost(postId: String, communityId: String, reason: String, token: String) async throws {
        let body = try? JSONSerialization.data(withJSONObject: ["reason": reason, "communityId": communityId])
        _ = try await client.fetch(OKResponse.self,
                                    path: "/posts/\(postId)/report",
                                    method: "POST", token: token, bodyData: body)
    }

    func reportMember(communityId: String, userId: String, reason: String, token: String) async throws {
        let body = try? JSONSerialization.data(withJSONObject: ["reason": reason])
        _ = try await client.fetch(OKResponse.self,
                                    path: "/communities/\(communityId)/members/\(userId)/report",
                                    method: "POST", token: token, bodyData: body)
    }
}

// MARK: - Private DTOs (only used inside this repository)

private struct DiscoverPayload: Decodable {
    let trending: [CommunityDTO]
    let recommended: [CommunityDTO]
}

private struct JoinStatusPayload: Decodable {
    let status: String
}

private struct EmptyPayload: Decodable {}

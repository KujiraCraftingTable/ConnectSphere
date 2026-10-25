import Foundation

/// Single access point for all community-related API calls.
/// All ViewModels in the Communities feature use this instead of calling NetworkClient directly.
struct CommunityRepository {
    private let client = NetworkClient.shared

    // MARK: - Discovery & Listing

    /// One mode's public communities (the server never mixes modes).
    func fetchCommunities(query: String = "", type: CommunityType, token: String) async throws -> [Community] {
        var items: [URLQueryItem] = [
            .init(name: "limit",  value: "20"),
            .init(name: "offset", value: "0"),
            .init(name: "type",   value: type.rawValue),
        ]
        if !query.isEmpty { items.append(.init(name: "query", value: query)) }

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

    func fetchDiscover(type: CommunityType, token: String) async throws -> (trending: [Community], recommended: [Community]) {
        let res = try await client.fetch(DataResponse<DiscoverPayload>.self,
                                         path: "/communities/discover", token: token,
                                         queryItems: [.init(name: "type", value: type.rawValue)])
        return (
            trending:    res.data.trending.map    { $0.toCommunity() },
            recommended: res.data.recommended.map { $0.toCommunity() }
        )
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

    /// Feed-visibility only — does not unfollow/leave the community.
    func mute(communityId: String, token: String) async throws {
        _ = try await client.fetch(OKResponse.self,
                                    path: "/communities/\(communityId)/mute",
                                    method: "PUT", token: token)
    }

    func unmute(communityId: String, token: String) async throws {
        _ = try await client.fetch(OKResponse.self,
                                    path: "/communities/\(communityId)/mute",
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

    /// Decodes as `PostDTO`/`Post` — the same model `PostCard` (and Feed)
    /// render — not the legacy `CommunityPost`, which is now only used as
    /// `PostComposerViewModel`'s internal create-response decode target.
    func fetchPosts(communityId: String, search: String? = nil, limit: Int, offset: Int, token: String) async throws -> [Post] {
        var items: [URLQueryItem] = [
            .init(name: "limit",  value: "\(limit)"),
            .init(name: "offset", value: "\(offset)"),
        ]
        if let search, !search.isEmpty { items.append(.init(name: "search", value: search)) }
        let res = try await client.fetch(DataListResponse<PostDTO>.self,
                                          path: "/communities/\(communityId)/posts",
                                          token: token, queryItems: items)
        return res.data.map { $0.toPost() }
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
        avatarUrl: String? = nil,
        description: String?,
        token: String
    ) async throws -> Community {
        struct Body: Encodable {
            let name, type, privacy, icon_emoji, cover_color: String
            let avatar_url: String?
            let description: String?
        }
        let body = NetworkClient.encode(Body(name: name, type: type, privacy: privacy,
                                             icon_emoji: iconEmoji, cover_color: coverColor,
                                             avatar_url: avatarUrl, description: description))
        let res = try await client.fetch(DataResponse<CommunityDTO>.self,
                                          path: "/communities", method: "POST",
                                          token: token, bodyData: body)
        return res.data.toCommunity(isMemberOverride: true)
    }

    /// Partial edit (name/description/privacy/icon/cover/avatar) — admin/moderator
    /// only, enforced server-side. A nil field leaves that column untouched.
    func updateCommunity(
        communityId: String,
        name: String? = nil,
        description: String? = nil,
        privacy: String? = nil,
        iconEmoji: String? = nil,
        coverColor: String? = nil,
        avatarUrl: String? = nil,
        token: String
    ) async throws -> Community {
        struct Body: Encodable {
            let name, description, privacy, icon_emoji, cover_color, avatar_url: String?
        }
        let body = NetworkClient.encode(Body(name: name, description: description, privacy: privacy,
                                             icon_emoji: iconEmoji, cover_color: coverColor, avatar_url: avatarUrl))
        let res = try await client.fetch(DataResponse<CommunityDTO>.self,
                                          path: "/communities/\(communityId)", method: "PATCH",
                                          token: token, bodyData: body)
        return res.data.toCommunity()
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

    // MARK: - Reports

    /// Reports a community member — or a post in the community
    /// (`targetType == "post"`). `detail` is optional free text.
    func report(targetType: String, targetId: String, communityId: String,
                reason: String, detail: String?, token: String) async throws {
        var body: [String: Any] = ["reason": reason]
        if let detail { body["detail"] = detail }
        let path: String
        if targetType == "post" {
            path = "/posts/\(targetId)/report"
            body["communityId"] = communityId
        } else {
            path = "/communities/\(communityId)/members/\(targetId)/report"
        }
        _ = try await client.fetch(OKResponse.self, path: path, method: "POST", token: token,
                                   bodyData: try? JSONSerialization.data(withJSONObject: body))
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

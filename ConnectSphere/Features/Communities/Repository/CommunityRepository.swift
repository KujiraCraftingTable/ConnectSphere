import Foundation

/// Single access point for all community-related API calls.
/// All ViewModels in the Communities feature use this instead of calling NetworkClient directly.
struct CommunityRepository {
    private let client = NetworkClient.shared

    // MARK: - Discovery & Listing

    /// One mode's public communities (the server never mixes modes).
    /// Whether `name` is free (ignoring case); `except` is the community being renamed.
    func isNameAvailable(_ name: String, except: String?, token: String) async throws -> Bool {
        struct Availability: Decodable { let available: Bool }
        var items: [URLQueryItem] = [.init(name: "name", value: name)]
        if let except { items.append(.init(name: "except", value: except)) }
        return try await client.fetch(DataResponse<Availability>.self, path: "/communities/name-available",
                                      token: token, queryItems: items).data.available
    }

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

    /// The community page was opened: orders My communities by how often.
    func recordOpened(communityId: String, token: String) async throws {
        _ = try await client.fetch(OKResponse.self, path: "/communities/\(communityId)/opened",
                                   method: "POST", token: token)
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

    /// Feed-visibility only, does not unfollow/leave the community.
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

    /// Decodes as `PostDTO`/`Post`. The same model `PostCard` (and Feed)
    /// render, not the legacy `CommunityPost`, which is now only used as
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

    func fetchMembers(communityId: String, search: String? = nil, limit: Int = 50, token: String) async throws -> [CommunityMember] {
        var items: [URLQueryItem] = [
            .init(name: "limit",  value: "\(limit)"),
            .init(name: "offset", value: "0"),
        ]
        if let search, !search.isEmpty { items.append(.init(name: "search", value: search)) }
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
        // The route answers `{data: {…role row}}`, with no `status`, so
        // decoding OKResponse failed after the role had already changed.
        _ = try await client.fetch(RoleUpdated.self,
                                    path: "/communities/\(communityId)/members/\(userId)/role",
                                    method: "PATCH", token: token, bodyData: body)
    }

    private struct RoleUpdated: Decodable {}

    // MARK: - Admin: disband, bans, moderation log

    func disband(communityId: String, confirmName: String, token: String) async throws {
        _ = try await client.fetch(OKResponse.self, path: "/communities/\(communityId)/disband",
                                   method: "POST", token: token, bodyData: NetworkClient.encode(["name": confirmName]))
    }

    func restore(communityId: String, token: String) async throws {
        _ = try await client.fetch(OKResponse.self, path: "/communities/\(communityId)/restore", method: "POST", token: token)
    }

    func banMember(communityId: String, userId: String, token: String) async throws {
        _ = try await client.fetch(OKResponse.self, path: "/communities/\(communityId)/members/\(userId)/ban",
                                   method: "POST", token: token)
    }

    func unbanMember(communityId: String, userId: String, token: String) async throws {
        _ = try await client.fetch(OKResponse.self, path: "/communities/\(communityId)/members/\(userId)/ban",
                                   method: "DELETE", token: token)
    }

    func fetchBans(communityId: String, token: String) async throws -> [BannedMember] {
        try await client.fetch(DataListResponse<BannedMember>.self, path: "/communities/\(communityId)/bans", token: token).data
    }

    func fetchModLog(communityId: String, offset: Int, limit: Int = 30, token: String) async throws -> [ModLogEntry] {
        let items: [URLQueryItem] = [.init(name: "limit", value: "\(limit)"), .init(name: "offset", value: "\(offset)")]
        return try await client.fetch(DataListResponse<ModLogEntry>.self, path: "/communities/\(communityId)/mod-log",
                                      token: token, queryItems: items).data
    }

    /// Hands the admin role to another member; the caller becomes a moderator.
    func transferAdmin(communityId: String, userId: String, token: String) async throws {
        let body = NetworkClient.encode(["user_id": userId])
        _ = try await client.fetch(OKResponse.self,
                                    path: "/communities/\(communityId)/transfer-admin",
                                    method: "POST", token: token, bodyData: body)
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

    func fetchReportCases(communityId: String, resolved: Bool, token: String) async throws -> CommunityReportQueue {
        let items: [URLQueryItem] = [
            .init(name: "status", value: resolved ? "resolved" : "pending"),
            .init(name: "limit", value: "50"),
        ]
        return try await client.fetch(DataResponse<CommunityReportQueue>.self,
                                      path: "/communities/\(communityId)/moderation",
                                      token: token, queryItems: items).data
    }

    func fetchReportCase(communityId: String, targetId: String, token: String) async throws -> CommunityReportDetail {
        try await client.fetch(DataResponse<CommunityReportDetail>.self,
                               path: "/communities/\(communityId)/reports/target/\(targetId)", token: token).data
    }

    func decideReportCase(communityId: String, targetId: String, decision: CommunityReportDecision,
                          note: String?, token: String) async throws {
        struct Body: Encodable { let decision: String; let note: String? }
        _ = try await client.fetch(DataResponse<EmptyPayload>.self,
                                   path: "/communities/\(communityId)/reports/target/\(targetId)",
                                   method: "PATCH", token: token,
                                   bodyData: NetworkClient.encode(Body(decision: decision.rawValue, note: note)))
    }

    // MARK: - Create Community

    func createCommunity(
        name: String,
        type: String,
        privacy: String,
        coverUrl: String,
        description: String?,
        token: String
    ) async throws -> Community {
        struct Body: Encodable {
            let name, type, privacy, cover_url: String
            let description: String?
            let description_format: String?
        }
        let body = NetworkClient.encode(Body(name: name, type: type, privacy: privacy,
                                             cover_url: coverUrl, description: description,
                                             description_format: description == nil ? nil : PostRepository.contentFormat))
        let res = try await client.fetch(DataResponse<CommunityDTO>.self,
                                          path: "/communities", method: "POST",
                                          token: token, bodyData: body)
        return res.data.toCommunity(isMemberOverride: true)
    }

    /// Partial edit, admin only, enforced server-side. A nil field leaves
    /// that column untouched; the cover can be replaced but not removed.
    func updateCommunity(
        communityId: String,
        name: String? = nil,
        description: String? = nil,
        privacy: String? = nil,
        coverUrl: String? = nil,
        requirePostApproval: Bool? = nil,
        token: String
    ) async throws -> Community {
        struct Body: Encodable {
            let name, description, description_format, privacy, cover_url: String?
            let require_post_approval: Bool?
        }
        let body = NetworkClient.encode(Body(name: name, description: description,
                                             description_format: description == nil ? nil : PostRepository.contentFormat,
                                             privacy: privacy, cover_url: coverUrl, require_post_approval: requirePostApproval))
        let res = try await client.fetch(DataResponse<CommunityDTO>.self,
                                          path: "/communities/\(communityId)", method: "PATCH",
                                          token: token, bodyData: body)
        return res.data.toCommunity()
    }
}

// MARK: - Pin / info

extension CommunityRepository {
    /// Pinned communities sit at the top of My communities.
    func setPinned(_ pinned: Bool, communityId: String, token: String) async throws {
        _ = try await client.fetch(OKResponse.self, path: "/communities/\(communityId)/pin",
                                   method: pinned ? "PUT" : "DELETE", token: token)
    }

    func setNotifyLevel(_ level: CommunityNotifyLevel, communityId: String, token: String) async throws {
        struct R: Decodable { let notify_level: String }
        _ = try await client.fetch(R.self, path: "/communities/\(communityId)/notifications", method: "PUT", token: token,
                                   bodyData: try JSONSerialization.data(withJSONObject: ["level": level.rawValue]))
    }

    /// A post on your own feed carrying the community's card.
    func shareToFeed(communityId: String, note: String, token: String) async throws {
        _ = try await client.fetch(DataResponse<PostDTO>.self, path: "/communities/\(communityId)/share",
                                   method: "POST", token: token,
                                   bodyData: try JSONSerialization.data(withJSONObject: ["content": note]))
    }

    func fetchMemberProfile(communityId: String, userId: String, offset: Int, token: String) async throws -> CommunityMemberProfile {
        try await client.fetch(CommunityMemberProfile.self, path: "/communities/\(communityId)/members/\(userId)/profile",
                               token: token, queryItems: [.init(name: "offset", value: String(offset))])
    }

    func fetchInfo(communityId: String, token: String) async throws -> CommunityInfo {
        try await client.fetch(CommunityInfo.self, path: "/communities/\(communityId)/info", token: token)
    }
}

// MARK: - Post approval / Manage your content

extension CommunityRepository {
    /// Staff: posts waiting for approval.
    func fetchPendingPosts(communityId: String, token: String) async throws -> [Post] {
        let res = try await client.fetch(DataListResponse<PostDTO>.self,
                                         path: "/communities/\(communityId)/pending-posts", token: token)
        return res.data.map { $0.toPost() }
    }

    func reviewPost(communityId: String, postId: String, approve: Bool, reason: String?, token: String) async throws {
        var body: [String: Any] = ["action": approve ? "approve" : "decline"]
        if let reason { body["reason"] = reason }
        struct R: Decodable { let status: String }
        _ = try await client.fetch(R.self, path: "/communities/\(communityId)/posts/\(postId)/review",
                                   method: "PATCH", token: token,
                                   bodyData: try JSONSerialization.data(withJSONObject: body))
    }

    func fetchMyContent(communityId: String, kind: MyCommunityContent.Kind, newestFirst: Bool,
                        status: MyCommunityContent.Status, offset: Int, token: String) async throws -> MyCommunityContent {
        try await client.fetch(MyCommunityContent.self, path: "/communities/\(communityId)/my-content", token: token,
                               queryItems: [.init(name: "kind", value: kind.rawValue),
                                            .init(name: "order", value: newestFirst ? "newest" : "oldest"),
                                            .init(name: "status", value: status.rawValue),
                                            .init(name: "offset", value: String(offset))])
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

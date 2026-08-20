import Foundation

/// Single access point for all user-search API calls.
struct UserRepository {
    private let client = NetworkClient.shared

    func fetchUsers(mode: AppMode, search: String? = nil, limit: Int = 20, offset: Int = 0) async throws -> [UserProfile] {
        let response = try await client.fetch(
            PaginatedResponse<UserDTO>.self,
            from: .listUsers(mode: mode.rawValue, search: search, limit: limit, offset: offset)
        )
        return response.data.map { $0.toUserProfile() }
    }

    func aiSearch(prompt: String, mode: AppMode, radiusKm: Int? = nil) async throws -> (users: [UserProfile], reasoning: String, criteria: AISearchCriteriaDTO?, tips: String, suggestions: [EntitySuggestionDTO], evidence: [String: [MatchEvidenceDTO]]) {
        let response = try await client.fetch(
            AISearchResponseDTO.self,
            from: .aiSearch(query: prompt, mode: mode.rawValue, radiusKm: radiusKm)
        )
        // Map userId → lý do khớp (mini CV) — giữ ngoài UserProfile vì chỉ AI search dùng
        let evidence = Dictionary(
            response.data.compactMap { dto -> (String, [MatchEvidenceDTO])? in
                guard let ev = dto.matchEvidence, !ev.isEmpty else { return nil }
                return (dto.id, ev)
            },
            uniquingKeysWith: { first, _ in first }
        )
        return (
            users: response.data.map { $0.toUserProfile() },
            reasoning: response.reasoning,
            criteria: response.criteria,
            tips: response.tips,
            suggestions: response.entity_suggestions,
            evidence: evidence
        )
    }

    private struct AliasConfirmBody: Encodable { let keyword: String; let entity_id: String }
    private struct AliasConfirmResponse: Decodable { let status: String; let canonical_name: String? }

    /// User xác nhận keyword vừa search thuộc canonical này → backend lưu alias.
    func confirmAlias(keyword: String, entityId: String) async throws {
        let body = NetworkClient.encode(AliasConfirmBody(keyword: keyword, entity_id: entityId))
        _ = try await client.fetch(
            AliasConfirmResponse.self,
            path: "/entities/alias",
            method: "POST",
            token: try token(),
            bodyData: body
        )
    }

    func fetchSuggestions(mode: AppMode) async throws -> [String] {
        let response = try await client.fetch(
            SearchSuggestionsDTO.self,
            from: .searchSuggestions(mode: mode.rawValue)
        )
        return response.suggestions
    }

    // MARK: - Block

    private struct BlockStatusResponse: Decodable { let blocked: Bool }

    private func token() throws -> String {
        guard let token = KeychainHelper.load(forKey: KeychainHelper.tokenKey) else {
            throw APIError.serverError(statusCode: 401, message: "Not authenticated")
        }
        return token
    }

    /// Mình có đang chặn user này không
    func fetchBlockStatus(userId: String) async throws -> Bool {
        let response = try await client.fetch(
            BlockStatusResponse.self,
            path: "/users/\(userId)/blocked",
            token: try token()
        )
        return response.blocked
    }

    func blockUser(userId: String) async throws {
        _ = try await client.fetch(
            BlockStatusResponse.self,
            path: "/users/\(userId)/block",
            method: "POST",
            token: try token()
        )
    }

    func unblockUser(userId: String) async throws {
        _ = try await client.fetch(
            BlockStatusResponse.self,
            path: "/users/\(userId)/block",
            method: "DELETE",
            token: try token()
        )
    }

    /// Danh sách user mình đang chặn (màn Blocked users trong Settings)
    func fetchBlockedUsers() async throws -> [BlockedUserDTO] {
        try await client.fetch(
            DataResponse<[BlockedUserDTO]>.self,
            path: "/users/blocked",
            token: try token()
        ).data
    }
}

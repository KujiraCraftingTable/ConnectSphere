import Foundation

/// Posted after a block/unblock succeeds — carries the target user's id in
/// `userInfo["userId"]`. Mirrors `.webSocketDidReconnect`'s pattern: any open
/// `ChatView` for that user observes this and refreshes its local block state
/// live, instead of staying stale until the view is torn down and rebuilt.
extension Notification.Name {
    static let userBlockStatusChanged = Notification.Name("UserRepository.blockStatusChanged")
}

/// One-directional + bidirectional block state between the current user and
/// another. `blocked` drives the Block/Unblock toggle's own label ("did *I*
/// block them"); `blockedEitherWay` drives UI that must reflect either
/// direction (e.g. disabling the chat composer).
struct BlockStatus {
    let blocked: Bool
    let blockedEitherWay: Bool
}

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

    func aiSearch(prompt: String, mode: AppMode, radiusKm: Int? = nil) async throws -> (users: [UserProfile], criteria: AISearchCriteriaDTO?, suggestions: [EntitySuggestionDTO], evidence: [String: [MatchEvidenceDTO]], warnings: [SearchWarningDTO]) {
        let response = try await client.fetch(
            AISearchResponseDTO.self,
            from: .aiSearch(query: prompt, mode: mode.rawValue, radiusKm: radiusKm)
        )
        // Map userId → match reasons (mini CV) — kept outside UserProfile since only AI search uses it
        let evidence = Dictionary(
            response.data.compactMap { dto -> (String, [MatchEvidenceDTO])? in
                guard let ev = dto.matchEvidence, !ev.isEmpty else { return nil }
                return (dto.id, ev)
            },
            uniquingKeysWith: { first, _ in first }
        )
        return (
            users: response.data.map { $0.toUserProfile() },
            criteria: response.criteria,
            suggestions: response.entity_suggestions,
            evidence: evidence,
            warnings: response.warnings
        )
    }

    private struct LocationClarifyBody: Encodable { let alias: String; let canonical: String }
    struct LocationClarifyResult: Decodable {
        let status:        String
        let resolved:      Bool
        let province_name: String?
    }

    /// User tells us what an unrecognized place actually is ("landmark hcmc" →
    /// "Landmark 81"). Backend geocodes the answer itself and reports whether it
    /// could place it, so the caller knows whether re-running the search is worthwhile.
    func clarifyLocation(alias: String, canonical: String) async throws -> LocationClarifyResult {
        let body = NetworkClient.encode(LocationClarifyBody(alias: alias, canonical: canonical))
        return try await client.fetch(
            LocationClarifyResult.self,
            path: "/locations/clarify",
            method: "POST",
            token: try token(),
            bodyData: body
        )
    }

    private struct AliasConfirmBody: Encodable { let keyword: String; let entity_id: String }
    private struct AliasConfirmResponse: Decodable { let status: String; let canonical_name: String? }

    /// User confirms the searched keyword belongs to this canonical entity → backend saves the alias.
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

    /// `blockedEitherWay` is optional to tolerate the backend not having landed
    /// the bidirectional field yet — falls back to `blocked` (one-directional)
    /// in `fetchBlockStatusDetailed` below when absent.
    private struct BlockStatusResponse: Decodable {
        let blocked: Bool
        let blockedEitherWay: Bool?
    }

    private func token() throws -> String {
        guard let token = KeychainHelper.load(forKey: KeychainHelper.tokenKey) else {
            throw APIError.serverError(statusCode: 401, message: "Not authenticated")
        }
        return token
    }

    /// Whether I'm currently blocking this user (one-directional — used by the
    /// Block/Unblock toggle's own state).
    func fetchBlockStatus(userId: String) async throws -> Bool {
        try await fetchBlockStatusDetailed(userId: userId).blocked
    }

    /// Both the one-directional and bidirectional block state with `userId`.
    /// Use `blockedEitherWay` to decide whether to disable the chat composer /
    /// show "You've blocked this user" — `blocked` alone misses the case where
    /// the *other* person blocked *me*.
    func fetchBlockStatusDetailed(userId: String) async throws -> BlockStatus {
        let response = try await client.fetch(
            BlockStatusResponse.self,
            path: "/users/\(userId)/blocked",
            token: try token()
        )
        return BlockStatus(
            blocked: response.blocked,
            blockedEitherWay: response.blockedEitherWay ?? response.blocked
        )
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

    /// List of users I'm currently blocking (the Blocked users screen in Settings)
    func fetchBlockedUsers() async throws -> [BlockedUserDTO] {
        try await client.fetch(
            DataResponse<[BlockedUserDTO]>.self,
            path: "/users/blocked",
            token: try token()
        ).data
    }
}

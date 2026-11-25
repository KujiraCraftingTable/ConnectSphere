import Foundation

// MARK: - Filter
/// Filter for the notification list. Mirrors the backend's `filter` query param.
enum NotificationFilter: String, CaseIterable {
    case all
    case unread
}

// MARK: - Repository
struct UserNotificationRepository {
    private let client = NetworkClient.shared

    /// One page of notifications, newest first.
    ///
    /// Pages with an opaque cursor rather than an offset: a collapsed chat row
    /// bumping to the top mid-scroll would make offset paging skip or repeat
    /// rows.
    func fetch(
        limit: Int = 30,
        cursor: String? = nil,
        filter: NotificationFilter = .all,
        mode: AppMode? = nil,
        token: String
    ) async throws -> UserNotificationListResponseDTO {
        var queryItems = [
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "filter", value: filter.rawValue),
        ]
        if let cursor { queryItems.append(URLQueryItem(name: "cursor", value: cursor)) }
        // Hobby and Work notifications are separate; each mode caches its own first page.
        if let mode { queryItems.append(URLQueryItem(name: "mode", value: mode.rawValue)) }
        let cacheKey = CacheStore.Key.notifications + (mode.map { "_\($0.rawValue)" } ?? "")

        // Cache only the first page of the default (All) filter. The offline
        // landing surface. Cursored / Unread-filtered fetches bypass it.
        let cacheable = cursor == nil && filter == .all
        do {
            let (response, body) = try await client.fetchRaw(
                UserNotificationListResponseDTO.self,
                path: "/user-notifications",
                token: token,
                queryItems: queryItems
            )
            if cacheable { await CacheStore.shared.put(cacheKey, body: body) }
            return response
        } catch {
            if cacheable, let cached = await CacheStore.shared.get(UserNotificationListResponseDTO.self, cacheKey) {
                return cached
            }
            throw error
        }
    }

    func fetchAll(token: String) async throws -> UserNotificationListResponseDTO {
        try await fetch(token: token)
    }

    // MARK: - Badge
    /// The tab badge: unread notifications that arrived since the tab was last left.
    func badgeCount(mode: AppMode, token: String) async throws -> Int {
        let response = try await client.fetch(
            DataResponse<UnreadCountPayloadDTO>.self,
            path: "/user-notifications/unread-count",
            token: token,
            queryItems: [URLQueryItem(name: "mode", value: mode.rawValue), URLQueryItem(name: "scope", value: "badge")]
        )
        return response.data.count
    }

    /// The Notifications tab was left: the badge starts again from zero.
    func markSeen(mode: AppMode, token: String) async throws {
        struct Empty: Decodable {}
        _ = try await client.fetch(
            Empty.self,
            path: "/user-notifications/seen",
            method: "POST",
            token: token,
            queryItems: [URLQueryItem(name: "mode", value: mode.rawValue)]
        )
    }

    // MARK: - Mismatch & actions
    /// Returns the first unresolved mode_mismatch notification for a specific post.
    func fetchMismatchFor(postId: String, token: String) async throws -> UserNotificationDTO? {
        let response = try await fetchAll(token: token)
        return response.data.first {
            $0.type == "mode_mismatch" &&
            $0.postId == postId &&
            $0.resolvedAt == nil
        }
    }

    func resolve(notificationId: String, action: String, token: String) async throws {
        struct Empty: Decodable {}
        let body = try? JSONEncoder().encode(["action": action])
        _ = try await client.fetch(
            Empty.self,
            path: "/user-notifications/\(notificationId)/resolve",
            method: "POST",
            token: token,
            bodyData: body
        )
    }

    // MARK: - Read state
    func markRead(notificationId: String, token: String) async throws {
        try await setRead(notificationId: notificationId, isRead: true, token: token)
    }

    func markUnread(notificationId: String, token: String) async throws {
        try await setRead(notificationId: notificationId, isRead: false, token: token)
    }

    private func setRead(notificationId: String, isRead: Bool, token: String) async throws {
        struct Empty: Decodable {}
        _ = try await client.fetch(
            Empty.self,
            path: "/user-notifications/\(notificationId)/\(isRead ? "read" : "unread")",
            method: "POST",
            token: token
        )
    }

    func markAllRead(mode: AppMode? = nil, token: String) async throws {
        struct Empty: Decodable {}
        _ = try await client.fetch(
            Empty.self,
            path: "/user-notifications/read-all",
            method: "POST",
            token: token,
            queryItems: mode.map { [URLQueryItem(name: "mode", value: $0.rawValue)] } ?? []
        )
    }
}

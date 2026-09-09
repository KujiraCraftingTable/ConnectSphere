import Foundation

/// Filter for the notification list. Mirrors the backend's `filter` query param.
enum NotificationFilter: String, CaseIterable {
    case all
    case unread
}

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
        token: String
    ) async throws -> UserNotificationListResponseDTO {
        var queryItems = [
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "filter", value: filter.rawValue),
        ]
        if let cursor { queryItems.append(URLQueryItem(name: "cursor", value: cursor)) }

        // Cache only the first page of the default (All) filter — the offline
        // landing surface. Cursored / Unread-filtered fetches bypass it.
        let cacheable = cursor == nil && filter == .all
        do {
            let (response, body) = try await client.fetchRaw(
                UserNotificationListResponseDTO.self,
                path: "/user-notifications",
                token: token,
                queryItems: queryItems
            )
            if cacheable { await CacheStore.shared.put(CacheStore.Key.notifications, body: body) }
            return response
        } catch {
            if cacheable, let cached = await CacheStore.shared.get(UserNotificationListResponseDTO.self, CacheStore.Key.notifications) {
                return cached
            }
            throw error
        }
    }

    func fetchAll(token: String) async throws -> UserNotificationListResponseDTO {
        try await fetch(token: token)
    }

    /// Unread total without pulling the whole list — used for the tab badge.
    func unreadCount(token: String) async throws -> Int {
        let response = try await client.fetch(
            DataResponse<UnreadCountPayloadDTO>.self,
            path: "/user-notifications/unread-count",
            token: token
        )
        return response.data.count
    }

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

    func markAllRead(token: String) async throws {
        struct Empty: Decodable {}
        _ = try await client.fetch(
            Empty.self,
            path: "/user-notifications/read-all",
            method: "POST",
            token: token
        )
    }

    func delete(notificationId: String, token: String) async throws {
        struct Empty: Decodable {}
        _ = try await client.fetch(
            Empty.self,
            path: "/user-notifications/\(notificationId)",
            method: "DELETE",
            token: token
        )
    }
}

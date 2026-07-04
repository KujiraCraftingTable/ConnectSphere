import Foundation
import Observation

@Observable
class NotificationsViewModel {
    var notifications: [CommunityNotification] = []
    var unreadCount: Int = 0
    var isLoading = false
    var errorMessage: String?
    var canLoadMore = true

    private let token: String
    private let client = NetworkClient.shared
    private let pageSize = 20
    private var offset = 0

    init(token: String) {
        self.token = token
    }

    func fetchNotifications(reset: Bool = false) async {
        if reset { offset = 0; canLoadMore = true; notifications = [] }
        guard canLoadMore else { return }
        isLoading = true
        do {
            let items: [URLQueryItem] = [
                .init(name: "limit",  value: "\(pageSize)"),
                .init(name: "offset", value: "\(offset)"),
            ]
            let res = try await client.fetch(DataListResponse<CommunityNotification>.self,
                                              path: "/notifications/communities",
                                              token: token, queryItems: items)
            notifications.append(contentsOf: res.data)
            offset += res.data.count
            canLoadMore = res.data.count == pageSize
        } catch {
            errorMessage = friendlyError(error)
        }
        isLoading = false
    }

    func fetchUnreadCount() async {
        do {
            let res = try await client.fetch(DataResponse<UnreadCountResponse>.self,
                                              path: "/notifications/unread-count", token: token)
            unreadCount = res.data.count
        } catch {
            // Silent — badge is non-critical
        }
    }

    func markAsRead(_ id: String) async {
        guard let idx = notifications.firstIndex(where: { $0.id == id }),
              !notifications[idx].isRead else { return }

        notifications[idx] = CommunityNotification(
            id: notifications[idx].id, type: notifications[idx].type,
            communityId: notifications[idx].communityId,
            communityName: notifications[idx].communityName,
            refId: notifications[idx].refId, isRead: true,
            createdAt: notifications[idx].createdAt
        )
        unreadCount = max(0, unreadCount - 1)

        do {
            _ = try await client.fetch(OKResponse.self,
                                        path: "/notifications/\(id)/read",
                                        method: "PATCH", token: token)
        } catch {
            // Silent — stale read state is acceptable
        }
    }

    func markAllAsRead() async {
        notifications = notifications.map { n in
            guard !n.isRead else { return n }
            return CommunityNotification(
                id: n.id, type: n.type, communityId: n.communityId,
                communityName: n.communityName, refId: n.refId,
                isRead: true, createdAt: n.createdAt
            )
        }
        unreadCount = 0
        do {
            _ = try await client.fetch(OKResponse.self,
                                        path: "/notifications/read-all",
                                        method: "PATCH", token: token)
        } catch {
            errorMessage = friendlyError(error)
        }
    }
}

import Foundation

/// A run of notifications that share a grouping key, rendered as one row —
/// "Anna and 2 others liked your post".
///
/// Grouping happens over the rows currently loaded, so a group can be split by
/// a pagination boundary. That is deliberate: merging across pages would need
/// server-side aggregation, which breaks per-row read state and swipe actions.
struct NotificationGroup: Identifiable {
    let representative: UserNotificationDTO
    let members: [UserNotificationDTO]

    var id: String { representative.id }
    var ids: [String] { members.map(\.id) }

    /// Unread if *any* member is unread, so a group never looks handled while
    /// part of it still isn't.
    var isRead: Bool { members.allSatisfy(\.isRead) }

    /// Distinct actor names, newest first — drives "Anna and 2 others".
    var actorNames: [String] {
        var seen = Set<String>()
        return members.compactMap { notif in
            guard let name = notif.payload.fromDisplayName, seen.insert(name).inserted else { return nil }
            return name
        }
    }

    /// How many events this row stands for: distinct actors for social rows,
    /// or the server's collapse count for a chat row.
    var eventCount: Int {
        max(members.count, representative.eventCount)
    }

    var otherActorCount: Int { max(actorNames.count - 1, 0) }
}

@Observable
@MainActor
final class NotificationsViewModel {
    private(set) var notifications: [UserNotificationDTO] = []
    private(set) var isLoading = false
    private(set) var isLoadingMore = false
    private(set) var unreadCount = 0

    private(set) var filter: NotificationFilter = .all

    private var nextCursor: String?
    private var hasMore = false
    private let repo = UserNotificationRepository()
    private let socketTag = "notificationsView"

    /// Rows collapsed into display groups, newest first.
    var groups: [NotificationGroup] {
        var order: [String] = []
        var buckets: [String: [UserNotificationDTO]] = [:]

        for notif in notifications {
            let key = notif.groupingKey
            if buckets[key] == nil {
                buckets[key] = []
                order.append(key)
            }
            buckets[key]?.append(notif)
        }

        return order.compactMap { key in
            guard let members = buckets[key], let first = members.first else { return nil }
            return NotificationGroup(representative: first, members: members)
        }
    }

    var isEmpty: Bool { !isLoading && notifications.isEmpty }

    // MARK: - Loading

    /// Switch the All/Unread filter and reload. Takes the token explicitly —
    /// a `didSet` observer has no way to reach one, so the reload would
    /// silently no-op.
    func setFilter(_ newValue: NotificationFilter, token: String, appState: AppState?) async {
        guard newValue != filter else { return }
        filter = newValue
        await load(token: token, appState: appState)
    }

    func load(token: String? = nil, appState: AppState? = nil) async {
        guard let token = token ?? appState?.authToken else { return }
        isLoading = true
        defer { isLoading = false }

        guard let response = try? await repo.fetch(filter: filter, token: token) else { return }
        notifications = response.data
        nextCursor    = response.nextCursor
        hasMore       = response.hasMore ?? false
        applyUnread(response.unread, to: appState)
    }

    /// Fetch the next page when the last row comes into view.
    func loadMoreIfNeeded(currentGroup group: NotificationGroup, token: String) async {
        guard hasMore, !isLoadingMore, let cursor = nextCursor else { return }
        guard group.id == groups.last?.id else { return }

        isLoadingMore = true
        defer { isLoadingMore = false }

        guard let response = try? await repo.fetch(cursor: cursor, filter: filter, token: token) else { return }
        // Guard against a row arriving twice if it was bumped between pages.
        let known = Set(notifications.map(\.id))
        notifications.append(contentsOf: response.data.filter { !known.contains($0.id) })
        nextCursor = response.nextCursor
        hasMore    = response.hasMore ?? false
    }

    // MARK: - Mutations
    //
    // Every mutation updates local state FIRST and reverts on failure. The old
    // implementation called the API and waited for a full reload, so a tapped
    // row kept its unread highlight until then.

    func markRead(group: NotificationGroup, token: String, appState: AppState?) async {
        await setRead(ids: group.ids.filter { id in
            notifications.first { $0.id == id }?.isRead == false
        }, isRead: true, token: token, appState: appState)
    }

    func toggleRead(group: NotificationGroup, token: String, appState: AppState?) async {
        await setRead(ids: group.ids, isRead: !group.isRead, token: token, appState: appState)
    }

    private func setRead(ids: [String], isRead: Bool, token: String, appState: AppState?) async {
        guard !ids.isEmpty else { return }
        let previous = notifications
        // Only rows actually changing state move the counter.
        let changed = ids.filter { id in
            notifications.first { $0.id == id }?.isRead == !isRead
        }.count
        apply(isRead: isRead, to: ids)
        adjustUnread(by: isRead ? -changed : changed, appState: appState)

        for id in ids {
            do {
                if isRead {
                    try await repo.markRead(notificationId: id, token: token)
                } else {
                    try await repo.markUnread(notificationId: id, token: token)
                }
            } catch {
                notifications = previous
                adjustUnread(by: isRead ? changed : -changed, appState: appState)
                return
            }
        }
    }

    func markAllRead(token: String, appState: AppState?) async {
        let previous = notifications
        apply(isRead: true, to: notifications.map(\.id))
        applyUnread(0, to: appState)

        do {
            try await repo.markAllRead(token: token)
            // The Unread filter should visibly empty out once everything is read.
            if filter == .unread { await load(token: token, appState: appState) }
        } catch {
            notifications = previous
            await load(token: token, appState: appState)
        }
    }

    func delete(group: NotificationGroup, token: String, appState: AppState?) async {
        let previous = notifications
        let ids = Set(group.ids)
        let removedUnread = group.members.filter { !$0.isRead }.count
        notifications.removeAll { ids.contains($0.id) }
        adjustUnread(by: -removedUnread, appState: appState)

        do {
            for id in group.ids {
                try await repo.delete(notificationId: id, token: token)
            }
        } catch {
            notifications = previous
            adjustUnread(by: removedUnread, appState: appState)
        }
    }

    func resolve(notification: UserNotificationDTO, action: String, token: String, appState: AppState?) async {
        try? await repo.resolve(notificationId: notification.id, action: action, token: token)
        await load(token: token, appState: appState)
    }

    // MARK: - Realtime

    /// Keep the list live: a new notification prepends, and read/delete events
    /// from this account's other devices are mirrored.
    func startListening(token: String, appState: AppState?) {
        let socket = WebSocketClient.shared

        socket.on("notification", tag: socketTag) { _ in
            Task { @MainActor in await self.load(token: token, appState: appState) }
        }
        socket.on("notification_read", tag: socketTag) { _ in
            Task { @MainActor in await self.load(token: token, appState: appState) }
        }
        socket.on("notification_deleted", tag: socketTag) { _ in
            Task { @MainActor in await self.load(token: token, appState: appState) }
        }
    }

    func stopListening() {
        let socket = WebSocketClient.shared
        socket.off("notification", tag: socketTag)
        socket.off("notification_read", tag: socketTag)
        socket.off("notification_deleted", tag: socketTag)
    }

    // MARK: - Private

    private func apply(isRead: Bool, to ids: [String]) {
        let target = Set(ids)
        notifications = notifications.map { notif in
            guard target.contains(notif.id) else { return notif }
            return notif.withIsRead(isRead)
        }
    }

    /// Adjust the shared unread total by a delta.
    ///
    /// A delta rather than a recount, because in the Unread filter the loaded
    /// rows are only the first page — recounting them would report a page size
    /// as the total.
    private func adjustUnread(by delta: Int, appState: AppState?) {
        guard delta != 0 else { return }
        applyUnread(max(unreadCount + delta, 0), to: appState)
    }

    private func applyUnread(_ count: Int, to appState: AppState?) {
        unreadCount = count
        appState?.notificationUnreadCount = count
    }
}

private extension UserNotificationDTO {
    /// Copy with a flipped read flag — the DTO is a `let`-only Decodable.
    func withIsRead(_ isRead: Bool) -> UserNotificationDTO {
        UserNotificationDTO(
            id: id, type: type, postId: postId, payload: payload,
            isRead: isRead, resolvedAt: resolvedAt, createdAt: createdAt,
            actorId: actorId, communityId: communityId, conversationId: conversationId,
            entityType: entityType, entityId: entityId, groupKey: groupKey,
            collapseCount: collapseCount, updatedAt: updatedAt,
            communityName: communityName, category: category, destination: destination
        )
    }
}

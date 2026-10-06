import Foundation
import Observation

/// Keeps the Notifications tab badge current: fetched on launch and tab
/// switch, and live over the socket. The count lives on `AppState`, which the
/// tab bar reads.
@MainActor
@Observable
final class NotificationBadgeViewModel {
    private let repository = UserNotificationRepository()

    func refresh(appState: AppState) async {
        guard let token = appState.authToken else { return }
        if let count = try? await repository.unreadCount(token: token) {
            appState.notificationUnreadCount = count
        }
    }

    /// The backend emits `notification_count` after every create/read/delete,
    /// so the badge follows without opening the tab. `notification` is still
    /// observed for older backends that only send that event.
    func startRealtime(appState: AppState) {
        guard let token = appState.authToken else { return }
        WebSocketClient.shared.connect(token: token)
        for event in ["notification_count", "notification"] {
            WebSocketClient.shared.on(event, tag: "mainTabBadge") { [weak self, appState] _ in
                Task { @MainActor in await self?.refresh(appState: appState) }
            }
        }
    }
}

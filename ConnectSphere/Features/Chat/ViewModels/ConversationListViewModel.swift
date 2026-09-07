import Foundation
import Observation

@MainActor
@Observable
class ConversationListViewModel {

    var conversations: [Conversation] = []
    var isLoading = false
    var error: String?
    var unreadCount: Int = 0

    // Active connections bar (accepted connections + realtime online status)
    var connections: [ConnectionItemDTO] = []
    var onlineUserIds: Set<String> = []

    /// Connections that are currently online — used for the active avatar row at the top of the Messages screen.
    var activeConnections: [ConnectionItemDTO] {
        connections.filter { onlineUserIds.contains($0.user.id) }
    }

    private let repository = MessageRepository()
    private let connectionRepo = ConnectionRepository()
    private let ws = WebSocketClient.shared

    // MARK: - Load

    func load(mode: String, token: String) async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            async let convs  = repository.fetchConversations(mode: mode, token: token)
            async let unread = repository.fetchUnreadCount(mode: mode, token: token)
            (conversations, unreadCount) = try await (convs, unread)
        } catch {
            self.error = Bundle.app.loc("Could not load conversations")
        }
    }

    /// Fetch the current mode's accepted connections for the active row.
    /// Errors here don't block the main screen (they just hide the active row).
    func loadConnections(mode: String) async {
        do {
            connections = try await connectionRepo.fetchConnections(mode: mode, status: "accepted")
        } catch {
            connections = []
        }
    }

    // MARK: - WebSocket: listen for new messages to refresh list

    func connectSocket(token: String) {
        guard ws.connectionState == .disconnected else { return }
        ws.connect(token: token)
    }

    func registerNewMessageHandler(mode: String, token: String) {
        ws.on("new_message", tag: "conversationList") { [weak self] _ in
            guard let self else { return }
            Task { await self.load(mode: mode, token: token) }
        }
    }

    // MARK: - Presence (realtime online status)

    func registerPresenceHandlers() {
        // Full snapshot on (re)connect / when explicitly requested again
        ws.on("presence_snapshot", tag: "presence") { [weak self] payload in
            guard let self,
                  let dict = payload as? [String: Any],
                  let ids = dict["userIds"] as? [String] else { return }
            self.onlineUserIds = Set(ids)
        }
        // Update each person as they go online/offline
        ws.on("presence_update", tag: "presence") { [weak self] payload in
            guard let self,
                  let dict = payload as? [String: Any],
                  let uid = dict["userId"] as? String,
                  let online = dict["online"] as? Bool else { return }
            if online { self.onlineUserIds.insert(uid) }
            else { self.onlineUserIds.remove(uid) }
        }
        // If the socket is already connected (returning to the tab), request a fresh snapshot right away
        ws.emit("get_presence")
    }

    func unregisterHandlers() {
        ws.off("new_message", tag: "conversationList")
        ws.off("presence_snapshot", tag: "presence")
        ws.off("presence_update", tag: "presence")
    }

    // MARK: - Open conversation

    func openConversation(with otherUserId: String, mode: String, token: String) async throws -> String {
        return try await repository.openConversation(otherUserId: otherUserId, mode: mode, token: token)
    }

    /// Create a new group conversation. Returns the new conversation's id so
    /// the caller can navigate straight into its `ChatView`.
    func createGroup(memberIds: [String], mode: String, name: String?, token: String) async throws -> String {
        try await repository.createGroup(memberIds: memberIds, mode: mode, name: name, token: token)
    }
}

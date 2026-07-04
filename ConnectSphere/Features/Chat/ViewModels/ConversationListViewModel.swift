import Foundation
import Observation

@MainActor
@Observable
class ConversationListViewModel {

    var conversations: [Conversation] = []
    var isLoading = false
    var error: String?
    var unreadCount: Int = 0

    private let repository = MessageRepository()
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
            self.error = "Could not load conversations"
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

    func unregisterHandlers() {
        ws.off("new_message", tag: "conversationList")
    }

    // MARK: - Open conversation

    func openConversation(with otherUserId: String, mode: String, token: String) async throws -> String {
        return try await repository.openConversation(otherUserId: otherUserId, mode: mode, token: token)
    }
}

import Foundation
import Observation

@MainActor
@Observable
class ChatViewModel {

    var messages: [Message] = []          // oldest → newest
    var isLoading = false
    var isSending = false
    var isOtherTyping = false
    var hasMoreMessages = false
    var error: String?

    private let conversationId: String
    private let currentUserId: String
    private let token: String
    private let repository = MessageRepository()
    private let ws = WebSocketClient.shared
    private var typingTask: Task<Void, Never>?

    init(conversationId: String, currentUserId: String, token: String) {
        self.conversationId = conversationId
        self.currentUserId  = currentUserId
        self.token          = token
    }

    // MARK: - Load messages

    func loadMessages() async {
        isLoading = true
        defer { isLoading = false }
        do {
            // API returns newest-first; reverse for display (oldest at top)
            let fetched = try await repository.fetchMessages(
                conversationId: conversationId, limit: 30, token: token
            )
            messages = fetched.reversed()
            hasMoreMessages = fetched.count == 30
        } catch {
            self.error = "Could not load messages"
        }
    }

    func loadOlderMessages() async {
        guard hasMoreMessages, let oldest = messages.first else { return }
        do {
            let older = try await repository.fetchMessages(
                conversationId: conversationId,
                limit: 30,
                before: oldest.createdAt,
                token: token
            )
            messages = older.reversed() + messages
            hasMoreMessages = older.count == 30
        } catch {
            self.error = "Could not load older messages"
        }
    }

    // MARK: - Send text

    func sendText(_ content: String) async {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isSending = true
        defer { isSending = false }

        if ws.connectionState == .connected {
            ws.emit("send_message", [
                "conversationId": conversationId,
                "content": trimmed,
                "messageType": "text"
            ])
        } else {
            do {
                let msg = try await repository.sendMessage(
                    conversationId: conversationId,
                    content: trimmed,
                    messageType: .text,
                    token: token
                )
                messages.append(msg)
            } catch {
                self.error = "Failed to send message"
            }
        }
    }

    // MARK: - Send media

    func sendMedia(fileURL: URL) async {
        isSending = true
        defer { isSending = false }
        do {
            let (url, type) = try await repository.uploadMedia(fileURL: fileURL, token: token)
            if ws.connectionState == .connected {
                ws.emit("send_message", [
                    "conversationId": conversationId,
                    "messageType": type.rawValue,
                    "mediaUrl": url
                ])
            } else {
                let msg = try await repository.sendMessage(
                    conversationId: conversationId,
                    content: nil,
                    messageType: type,
                    mediaUrl: url,
                    token: token
                )
                messages.append(msg)
            }
        } catch {
            self.error = "Failed to upload media"
        }
    }

    // MARK: - WebSocket setup

    func joinConversation() {
        ws.emit("join_conversation", conversationId)

        ws.on("new_message", tag: "chat") { [weak self] payload in
            guard let self,
                  let msg = self.decodeMessage(payload) else { return }
            if !self.messages.contains(where: { $0.id == msg.id }) {
                self.messages.append(msg)
            }
        }

        ws.on("user_typing", tag: "chat") { [weak self] payload in
            guard let self,
                  let dict = payload as? [String: Any],
                  let userId = dict["userId"] as? String,
                  userId != self.currentUserId,
                  let isTyping = dict["isTyping"] as? Bool else { return }
            self.handleTyping(isTyping)
        }

        ws.on("messages_read", tag: "chat") { [weak self] payload in
            guard let self,
                  let dict = payload as? [String: Any],
                  let convId = dict["conversationId"] as? String,
                  convId == self.conversationId else { return }
            for i in self.messages.indices {
                if self.messages[i].status != .read {
                    self.messages[i].status = .read
                }
            }
        }

        ws.on("message_deleted", tag: "chat") { [weak self] payload in
            guard let self,
                  let dict = payload as? [String: Any],
                  let convId = dict["conversation_id"] as? String,
                  convId == self.conversationId,
                  let messageId = dict["message_id"] as? String,
                  let i = self.messages.firstIndex(where: { $0.id == messageId }) else { return }
            self.messages[i].markDeleted()
        }
    }

    func leaveConversation() {
        typingTask?.cancel()
        ws.emit("leave_conversation", conversationId)
        ws.off("new_message", tag: "chat")
        ws.off("user_typing",   tag: "chat")
        ws.off("messages_read", tag: "chat")
        ws.off("message_deleted", tag: "chat")
    }

    // MARK: - Recall (thu hồi)

    /// Thu hồi tin nhắn của mình; cập nhật tại chỗ ngay, server sẽ phát
    /// message_deleted cho phía bên kia.
    func recallMessage(_ message: Message) async {
        guard message.senderId == currentUserId, !message.isDeleted else { return }
        do {
            try await repository.recallMessage(
                conversationId: conversationId,
                messageId: message.id,
                token: token
            )
            if let i = messages.firstIndex(where: { $0.id == message.id }) {
                messages[i].markDeleted()
            }
        } catch {
            self.error = "Could not recall message"
        }
    }

    // MARK: - Mark read

    func markRead() {
        ws.emit("mark_read", ["conversationId": conversationId])
    }

    // MARK: - Typing indicator

    func sendTyping(_ isTyping: Bool) {
        ws.emit("typing", ["conversationId": conversationId, "isTyping": isTyping])
    }

    // MARK: - Helpers

    private func handleTyping(_ isTyping: Bool) {
        typingTask?.cancel()
        self.isOtherTyping = isTyping
        if isTyping {
            typingTask = Task {
                try? await Task.sleep(for: .seconds(3))
                if !Task.isCancelled { self.isOtherTyping = false }
            }
        }
    }

    private func decodeMessage(_ payload: Any) -> Message? {
        guard let json = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        return try? JSONDecoder.makeISO8601().decode(Message.self, from: json)
    }
}

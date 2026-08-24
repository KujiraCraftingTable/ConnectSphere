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

    // Per-conversation settings: shared theme/nickname + my own mute
    var chatThemeId: String?
    var otherNickname: String?
    var mutedUntil: Date?

    /// Whether this conversation is currently muted for me.
    var isMuted: Bool {
        guard let mutedUntil else { return false }
        return mutedUntil > Date()
    }

    private let conversationId: String
    private let currentUserId: String
    private let otherUserId: String
    private let token: String
    private let repository = MessageRepository()
    private let ws = WebSocketClient.shared
    private var typingTask: Task<Void, Never>?

    init(conversationId: String, currentUserId: String, otherUserId: String, token: String) {
        self.conversationId = conversationId
        self.currentUserId  = currentUserId
        self.otherUserId    = otherUserId
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

    /// Load lùi lịch sử tới khi gặp messageId (tối đa maxPages trang) —
    /// phục vụ nhảy tới tin nhắn từ kết quả tìm kiếm.
    /// Trả về true nếu message có mặt trong danh sách sau khi load.
    func loadUntilFound(messageId: String, maxPages: Int = 10) async -> Bool {
        if messages.contains(where: { $0.id == messageId }) { return true }
        var pages = 0
        while hasMoreMessages && pages < maxPages {
            await loadOlderMessages()
            pages += 1
            if messages.contains(where: { $0.id == messageId }) { return true }
        }
        return false
    }

    // MARK: - Settings

    /// Load shared theme/nickname + my mute state for this conversation.
    func loadSettings() async {
        do {
            let s = try await repository.fetchSettings(conversationId: conversationId, token: token)
            chatThemeId   = s.theme
            otherNickname = s.otherUserNickname
            mutedUntil    = s.mutedUntil
        } catch {
            // Settings are non-critical; keep chat usable without them.
        }
    }

    // MARK: - Send text

    func sendText(_ content: String, replyTo replyToMessageId: String? = nil) async {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isSending = true
        defer { isSending = false }

        if ws.connectionState == .connected {
            var payload: [String: Any] = [
                "conversationId": conversationId,
                "content": trimmed,
                "messageType": "text"
            ]
            if let replyToMessageId { payload["replyToMessageId"] = replyToMessageId }
            ws.emit("send_message", payload)
        } else {
            do {
                let msg = try await repository.sendMessage(
                    conversationId: conversationId,
                    content: trimmed,
                    messageType: .text,
                    replyToMessageId: replyToMessageId,
                    token: token
                )
                messages.append(msg)
            } catch {
                self.error = "Failed to send message"
            }
        }
    }

    // MARK: - Send media

    func sendMedia(fileURL: URL, replyTo replyToMessageId: String? = nil) async {
        isSending = true
        defer { isSending = false }
        do {
            let (url, type) = try await repository.uploadMedia(fileURL: fileURL, token: token)
            if ws.connectionState == .connected {
                var payload: [String: Any] = [
                    "conversationId": conversationId,
                    "messageType": type.rawValue,
                    "mediaUrl": url
                ]
                if let replyToMessageId { payload["replyToMessageId"] = replyToMessageId }
                ws.emit("send_message", payload)
            } else {
                let msg = try await repository.sendMessage(
                    conversationId: conversationId,
                    content: nil,
                    messageType: type,
                    mediaUrl: url,
                    replyToMessageId: replyToMessageId,
                    token: token
                )
                messages.append(msg)
            }
        } catch {
            self.error = "Failed to upload media"
        }
    }

    // MARK: - Meeting proposals

    /// Propose a meeting (title/location/starts_at/ends_at) in this conversation.
    /// Prefers the socket (server fans out `new_message` to both sides, same as
    /// text/media); falls back to REST when disconnected, appending the result
    /// locally since no broadcast will arrive to add this bubble.
    func sendMeetingProposal(title: String, location: String?, startsAt: Date, endsAt: Date?) async {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return }
        isSending = true
        defer { isSending = false }

        if ws.connectionState == .connected {
            let iso = ISO8601DateFormatter()
            var proposalPayload: [String: Any] = [
                "title": trimmedTitle,
                "startsAt": iso.string(from: startsAt)
            ]
            if let location, !location.isEmpty { proposalPayload["location"] = location }
            if let endsAt { proposalPayload["endsAt"] = iso.string(from: endsAt) }
            ws.emit("send_message", [
                "conversationId": conversationId,
                "messageType": "meeting",
                "meetingProposal": proposalPayload
            ])
        } else {
            do {
                let msg = try await repository.sendMeetingProposal(
                    conversationId: conversationId, title: trimmedTitle, location: location,
                    startsAt: startsAt, endsAt: endsAt, token: token
                )
                messages.append(msg)
            } catch {
                self.error = "Failed to send meeting proposal"
            }
        }
    }

    /// Reschedule an existing meeting proposal (proposer only — the server clears
    /// prior RSVPs). Prefers the socket (server fans out `meeting_proposal_updated`
    /// to both sides); falls back to REST when disconnected, applying the result
    /// locally since no broadcast will arrive for this bubble.
    func rescheduleMeeting(messageId: String, title: String, location: String?, startsAt: Date, endsAt: Date?) async {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return }

        if ws.connectionState == .connected {
            let iso = ISO8601DateFormatter()
            var payload: [String: Any] = [
                "conversationId": conversationId,
                "messageId": messageId,
                "title": trimmedTitle,
                "startsAt": iso.string(from: startsAt)
            ]
            payload["location"] = (location?.isEmpty == false) ? location! : NSNull()
            payload["endsAt"] = endsAt.map { iso.string(from: $0) } ?? NSNull()
            ws.emit("update_meeting_proposal", payload)
        } else {
            do {
                let proposal = try await repository.updateMeetingProposal(
                    conversationId: conversationId, messageId: messageId, title: trimmedTitle,
                    location: location, startsAt: startsAt, endsAt: endsAt, token: token
                )
                if let i = messages.firstIndex(where: { $0.id == messageId }) {
                    messages[i].meetingProposal = proposal
                }
            } catch {
                self.error = "Could not reschedule meeting"
            }
        }
    }

    /// Cancel a meeting proposal (proposer only). Socket-first with REST fallback,
    /// same pattern as `rescheduleMeeting`.
    func cancelMeeting(messageId: String) async {
        if ws.connectionState == .connected {
            ws.emit("cancel_meeting_proposal", [
                "conversationId": conversationId,
                "messageId": messageId
            ])
        } else {
            do {
                let proposal = try await repository.cancelMeetingProposal(
                    conversationId: conversationId, messageId: messageId, token: token
                )
                if let i = messages.firstIndex(where: { $0.id == messageId }) {
                    messages[i].meetingProposal = proposal
                }
            } catch {
                self.error = "Could not cancel meeting"
            }
        }
    }

    /// RSVP to a meeting proposal. Socket-first with REST fallback, mirroring
    /// `sendReaction`'s exact branching.
    func respondToMeeting(messageId: String, status: MeetingRsvpStatus) async {
        if ws.connectionState == .connected {
            ws.emit("respond_meeting", [
                "conversationId": conversationId,
                "messageId": messageId,
                "status": status.rawValue
            ])
        } else {
            do {
                let proposal = try await repository.respondToMeeting(
                    conversationId: conversationId, messageId: messageId, status: status.rawValue, token: token
                )
                if let i = messages.firstIndex(where: { $0.id == messageId }) {
                    messages[i].meetingProposal = proposal
                }
            } catch {
                self.error = "Could not respond to meeting"
            }
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

        // A reaction was added/changed/removed on a message (either participant)
        ws.on("reaction_updated", tag: "chat") { [weak self] payload in
            guard let self,
                  let dict = payload as? [String: Any],
                  let convId = dict["conversation_id"] as? String,
                  convId == self.conversationId,
                  let messageId = dict["message_id"] as? String,
                  let reactions = dict["reactions"] as? [String: [String]],
                  let i = self.messages.firstIndex(where: { $0.id == messageId }) else { return }
            self.messages[i].reactions = reactions
        }

        // A meeting proposal was rescheduled or cancelled (proposer-only actions);
        // apply whatever the server sends — a reschedule's response already
        // reflects cleared RSVP counts/userResponse, so no extra clearing needed.
        ws.on("meeting_proposal_updated", tag: "chat") { [weak self] payload in
            guard let self,
                  let dict = payload as? [String: Any],
                  let convId = dict["conversation_id"] as? String,
                  convId == self.conversationId,
                  let messageId = dict["message_id"] as? String,
                  let i = self.messages.firstIndex(where: { $0.id == messageId }),
                  let proposal = self.decodeMeetingProposal(dict) else { return }
            self.messages[i].meetingProposal = proposal
        }

        // Someone RSVPed to a meeting proposal (going/maybe/not_going)
        ws.on("meeting_response_updated", tag: "chat") { [weak self] payload in
            guard let self,
                  let dict = payload as? [String: Any],
                  let convId = dict["conversation_id"] as? String,
                  convId == self.conversationId,
                  let messageId = dict["message_id"] as? String,
                  let i = self.messages.firstIndex(where: { $0.id == messageId }),
                  let proposal = self.decodeMeetingProposal(dict) else { return }
            self.messages[i].meetingProposal = proposal
        }

        // Shared settings (theme/nickname) changed by either participant
        ws.on("conversation_settings_updated", tag: "chat") { [weak self] payload in
            guard let self,
                  let dict = payload as? [String: Any],
                  let convId = dict["conversation_id"] as? String,
                  convId == self.conversationId else { return }
            self.chatThemeId = dict["theme"] as? String
            if let targetId = dict["nickname_target_id"] as? String, targetId == self.otherUserId {
                self.otherNickname = dict["nickname"] as? String
            }
        }
    }

    func leaveConversation() {
        typingTask?.cancel()
        ws.emit("leave_conversation", conversationId)
        ws.off("new_message", tag: "chat")
        ws.off("user_typing",   tag: "chat")
        ws.off("messages_read", tag: "chat")
        ws.off("message_deleted", tag: "chat")
        ws.off("reaction_updated", tag: "chat")
        ws.off("meeting_proposal_updated", tag: "chat")
        ws.off("meeting_response_updated", tag: "chat")
        ws.off("conversation_settings_updated", tag: "chat")
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

    // MARK: - Reactions

    /// React to a message (toggle off if re-tapping the same emoji, else set/replace).
    /// Prefers the socket (server also fans out `reaction_updated` to the other side);
    /// falls back to REST when disconnected, applying the result locally since no
    /// socket broadcast will arrive to update this bubble.
    func sendReaction(messageId: String, emoji: String) async {
        if ws.connectionState == .connected {
            ws.emit("react_message", [
                "conversationId": conversationId,
                "messageId": messageId,
                "emoji": emoji
            ])
        } else {
            do {
                let reactions = try await repository.react(
                    conversationId: conversationId, messageId: messageId, emoji: emoji, token: token
                )
                if let i = messages.firstIndex(where: { $0.id == messageId }) {
                    messages[i].reactions = reactions
                }
            } catch {
                self.error = "Could not react to message"
            }
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

    /// Decodes a meeting proposal from a `meeting_proposal_updated`/`meeting_response_updated`
    /// socket payload — accepts either a nested `meeting_proposal` dict (mirroring the REST
    /// embed shape used elsewhere) or the proposal's fields flattened at the payload's top
    /// level, to tolerate whichever broadcast shape the backend ends up sending.
    private func decodeMeetingProposal(_ dict: [String: Any]) -> MeetingProposal? {
        let proposalDict = (dict["meeting_proposal"] as? [String: Any]) ?? dict
        guard let json = try? JSONSerialization.data(withJSONObject: proposalDict) else { return nil }
        return try? JSONDecoder.makeISO8601().decode(MeetingProposal.self, from: json)
    }
}

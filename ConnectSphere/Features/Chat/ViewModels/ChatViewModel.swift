import Foundation
import Observation

@MainActor
@Observable
class ChatViewModel {

    var messages: [Message] = []          // oldest → newest
    var isLoading = false
    var isSending = false
    /// Ids of participants currently typing (excludes the current user). A
    /// 1:1 conversation has at most one id in here; a group can have several.
    var typingUserIds: Set<String> = []
    var hasMoreMessages = false
    var error: String?

    // Per-conversation settings: shared theme + my own mute (both kinds)
    var chatThemeId: String?
    var mutedUntil: Date?

    // 1:1-only settings
    var otherNickname: String?
    /// Message request state for this 1-on-1 chat (nil once it's a normal chat).
    var requestState: MessageRequestState?
    /// Messages I can still send before they accept (`.sent` only).
    var requestsLeft: Int?
    /// I started this chat with someone who isn't a friend and used up my messages.
    var isWaitingForAcceptance: Bool { requestState == .sent && (requestsLeft ?? 1) <= 0 }

    // Group-only settings (populated when `isGroup`)
    var groupName: String?
    var groupAvatarUrl: String?
    var groupAvatarColor: String?
    var groupCreatedBy: String?
    var groupMembers: [GroupMember] = []

    /// Set once the current user has been removed from this group (by the
    /// owner, or by leaving themselves) — `ChatView` observes this to
    /// navigate back out, since the conversation is no longer accessible.
    var wasRemovedFromGroup = false

    /// Non-nil (and `shouldAlert == true`) when a blocked/blocking person is
    /// in this group and hasn't been acknowledged yet. Groups only — 1:1
    /// keeps its existing hard-block behaviour untouched.
    var blockAlertState: (shouldAlert: Bool, blockedUserIds: [String])?

    /// Live, socket-updated pins for this conversation (server caps at 10) —
    /// drives `ChatView`'s pinned-banner and the context menu's Pin/Unpin
    /// label. `ChatSettingsViewModel` keeps its own separate copy for the
    /// settings-sheet-scoped `ChatPinnedMessagesView` list.
    var pinnedMessages: [PinnedMessage] = []

    /// Ids of currently pinned messages, for an O(1) "is this pinned?" check.
    var pinnedMessageIds: Set<String> { Set(pinnedMessages.map(\.id)) }

    /// Whether this conversation is currently muted for me.
    var isMuted: Bool {
        guard let mutedUntil else { return false }
        return mutedUntil > Date()
    }

    /// "X is typing…" / "N people are typing…" summary for the typing
    /// indicator — formatted here so `ChatView` doesn't need its own
    /// singular/plural or 1:1-vs-group branching.
    var typingSummary: String? {
        guard !typingUserIds.isEmpty else { return nil }
        guard isGroup else { return "Typing…" }
        if typingUserIds.count == 1, let id = typingUserIds.first {
            let name = groupMembers.first(where: { $0.id == id })?.displayName ?? "Someone"
            return "\(name) is typing…"
        }
        return "\(typingUserIds.count) people are typing…"
    }

    let isGroup: Bool
    /// Not `private` — `FloatingChatPresenter` keys its bubbles by this so at
    /// most one bubble exists per conversation.
    let conversationId: String
    private let currentUserId: String
    /// The other 1:1 participant's id — nil for groups (no single "other person").
    private let otherUserId: String?
    private let token: String
    private let repository = MessageRepository()
    private let ws = WebSocketClient.shared
    /// One typing-timeout task per currently-typing user id, so each
    /// participant's 3-second "stopped typing" timer runs independently
    /// (a single shared task would reset everyone's timer on any keystroke).
    private var typingTasks: [String: Task<Void, Never>] = [:]
    /// Token for the `.webSocketDidReconnect` observer registered in `joinConversation()`;
    /// removed symmetrically in `leaveConversation()`.
    private var reconnectObserver: NSObjectProtocol?
    /// Registration key for every `ws.on(...)`/`ws.off(...)` call below. Plain
    /// `"chat"` for a normal full-screen `ChatView`; `FloatingChatPresenter`
    /// re-tags this to `"chatBubble-<conversationId>"` when minimizing a
    /// conversation into a floating bubble — `WebSocketClient` stores exactly
    /// one handler per (event, tag) pair, so two different `ChatViewModel`
    /// instances sharing the same tag would silently clobber each other's
    /// listeners (e.g. a full `ChatView` opened on a different conversation
    /// while a bubble for this one is still live, both tagged plain "chat").
    private var socketTag = "chat"
    /// Guards `joinConversation()`/`leaveConversation()` against double
    /// registration — needed because a bubble's already-joined view model can
    /// be handed straight into a freshly-created `ChatView` (restoring from a
    /// floating bubble), whose own `.task` calls `joinConversation()` again.
    private(set) var hasJoinedConversation = false

    init(conversationId: String, currentUserId: String, isGroup: Bool, otherUserId: String?, token: String) {
        self.conversationId = conversationId
        self.currentUserId  = currentUserId
        self.isGroup        = isGroup
        self.otherUserId    = otherUserId
        self.token          = token
    }

    /// Re-tags this view model's socket listeners — tears down whatever's
    /// registered under the current tag and re-registers everything under
    /// `newTag`. Used only by `FloatingChatPresenter` when a conversation
    /// transitions between a full `ChatView` and a floating bubble.
    func retag(to newTag: String) {
        guard newTag != socketTag else { return }
        let wasJoined = hasJoinedConversation
        if wasJoined { leaveConversation() }
        socketTag = newTag
        if wasJoined { joinConversation() }
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
            self.error = Bundle.app.loc("Could not load messages")
        }
    }

    private var isLoadingOlder = false

    func loadOlderMessages() async {
        // One page at a time — a fast scroll-to-top fires this repeatedly, and
        // without the guard every call reads the same `oldest` and prepends a
        // duplicate page.
        guard !isLoadingOlder, hasMoreMessages, let oldest = messages.first else { return }
        isLoadingOlder = true
        defer { isLoadingOlder = false }
        do {
            let older = try await repository.fetchMessages(
                conversationId: conversationId,
                limit: 30,
                before: oldest.createdAt,
                token: token
            )
            let existingIds = Set(messages.map(\.id))
            let fresh = older.reversed().filter { !existingIds.contains($0.id) }
            messages = fresh + messages
            hasMoreMessages = older.count == 30
        } catch {
            self.error = friendlyError(error)
        }
    }

    /// Load older history pages until messageId is found (up to maxPages pages) —
    /// used for jumping to a message from search results.
    /// Returns true if the message is present in the list after loading.
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

    /// Load shared theme + my mute state, plus 1:1 nickname or group identity
    /// (name/photo/members) depending on `isGroup`.
    func loadSettings() async {
        do {
            let s = try await repository.fetchSettings(conversationId: conversationId, token: token)
            applySettings(s)
        } catch {
            // Settings are non-critical; keep chat usable without them.
        }
    }

    private func applySettings(_ s: ConversationSettings) {
        chatThemeId = s.theme
        mutedUntil  = s.mutedUntil
        if s.isGroup {
            groupName        = s.groupName
            groupAvatarUrl   = s.groupAvatarUrl
            groupAvatarColor = s.groupAvatarColor
            groupCreatedBy   = s.groupCreatedBy
            groupMembers     = s.members
        } else {
            otherNickname = s.otherUserNickname
            requestState = s.requestState
            requestsLeft = s.requestsLeft
        }
    }

    /// Clears this chat for me (it leaves my list until a new message arrives).
    func deleteChatForMe() async -> Bool {
        do {
            try await repository.clearConversation(conversationId: conversationId, token: token)
            return true
        } catch {
            self.error = friendlyError(error)
            return false
        }
    }

    /// Accept their message request (I'm the recipient) — same as replying.
    func acceptRequest() async {
        do {
            try await repository.acceptRequest(conversationId: conversationId, token: token)
            requestState = nil
        } catch {
            self.error = friendlyError(error)
        }
    }

    /// Keeps the "N messages left" warning in step after each send, and treats
    /// my reply to a waiting request as accepting it (the server does the same).
    private func noteMessageSent() {
        switch requestState {
        case .sent: requestsLeft = max(0, (requestsLeft ?? 0) - 1)
        case .waiting: requestState = nil
        case nil: break
        }
    }

    // MARK: - Group management

    /// Leave this group (any member). Sets `wasRemovedFromGroup` so `ChatView`
    /// navigates back out, mirroring what happens when the owner removes me.
    /// (Add/remove/promote/rename/photo live on `GroupParticipantsViewModel`
    /// and `ChatSettingsViewModel` instead — each screen owns the mutations it
    /// actually performs, matching this codebase's existing per-screen-VM
    /// pattern. `leaveGroup` lives here because it's driven directly from
    /// `ChatView`'s block-alert "Leave the group" action.)
    func leaveGroup() async {
        guard isGroup else { return }
        do {
            try await repository.leaveGroup(conversationId: conversationId, token: token)
            wasRemovedFromGroup = true
        } catch {
            self.error = friendlyError(error)
        }
    }

    // MARK: - Block alert (groups only)

    /// Checks whether a blocked/blocking person is in this group and hasn't
    /// been acknowledged yet; populates `blockAlertState` only when it should
    /// fire, so `ChatView` can drive its Leave/Stay alert off `!= nil`.
    func checkBlockAlert() async {
        guard isGroup else { return }
        do {
            let state = try await repository.fetchBlockAlertState(conversationId: conversationId, token: token)
            blockAlertState = state.shouldAlert ? state : nil
        } catch {
            // Non-critical; skip the alert silently on failure.
        }
    }

    /// Acknowledge the currently-alerted blocked-set ("Stay" path) so it
    /// doesn't re-fire until the blocked-set changes.
    func acknowledgeBlockAlert() async {
        guard isGroup else { return }
        do {
            try await repository.acknowledgeBlockAlert(conversationId: conversationId, token: token)
        } catch {
            // Non-critical; worst case the alert re-fires next time.
        }
        blockAlertState = nil
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
            if case .failure(let err) = await emitWithAck("send_message", payload) {
                // Server reasons (e.g. the message-request limit) have vi entries.
                self.error = Bundle.app.loc(friendlyError(err))
            } else {
                noteMessageSent()
            }
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
                noteMessageSent()
            } catch {
                if case APIError.serverError(403, _) = error {
                    self.error = Bundle.app.loc(friendlyError(error))
                } else {
                    self.error = Bundle.app.loc("Failed to send message")
                }
            }
        }
    }

    // MARK: - Send media

    /// `voiceDurationSeconds`/`voiceWaveform` are only ever passed for a
    /// recorded voice message (`VoiceRecorderControl`'s stop callback) —
    /// every other caller (photo/video attachment) leaves them nil, mirroring
    /// how `mediaUrl` is already the only required extra field for those types.
    func sendMedia(
        fileURL: URL,
        replyTo replyToMessageId: String? = nil,
        voiceDurationSeconds: Int? = nil,
        voiceWaveform: [Float]? = nil
    ) async {
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
                if let voiceDurationSeconds { payload["voiceDurationSeconds"] = voiceDurationSeconds }
                if let voiceWaveform { payload["voiceWaveform"] = voiceWaveform }
                if case .failure(let err) = await emitWithAck("send_message", payload) {
                    self.error = Bundle.app.loc(friendlyError(err))
                } else {
                    noteMessageSent()
                }
            } else {
                let msg = try await repository.sendMessage(
                    conversationId: conversationId,
                    content: nil,
                    messageType: type,
                    mediaUrl: url,
                    replyToMessageId: replyToMessageId,
                    voiceDurationSeconds: voiceDurationSeconds,
                    voiceWaveform: voiceWaveform,
                    token: token
                )
                messages.append(msg)
                noteMessageSent()
            }
        } catch {
            self.error = Bundle.app.loc("Failed to upload media")
        }
    }

    // MARK: - Albums

    static let maxAlbumPhotos = 10

    /// Splits what's in the composer the way it gets sent: 2–10 photos travel
    /// together as one album (carrying the typed text as its caption); a lone
    /// photo and every video go one per message, as before.
    static func plan(mediaFiles: [URL]) -> (album: [URL], singles: [URL]) {
        let isVideo = { (url: URL) in ["mp4", "mov"].contains(url.pathExtension.lowercased()) }
        let photos = mediaFiles.filter { !isVideo($0) }
        guard photos.count >= 2 else { return ([], mediaFiles) }
        let album = Array(photos.prefix(maxAlbumPhotos))
        return (album, mediaFiles.filter { !album.contains($0) })
    }

    /// Uploads the photos side by side (order kept), then sends them as one
    /// album message with an optional caption.
    func sendAlbum(fileURLs: [URL], caption: String?, replyTo replyToMessageId: String? = nil) async {
        isSending = true
        defer { isSending = false }
        let repository = repository, token = token
        do {
            let uploaded = try await withThrowingTaskGroup(of: (Int, String).self) { group in
                for (index, file) in fileURLs.enumerated() {
                    group.addTask { (index, try await repository.uploadMedia(fileURL: file, token: token).url) }
                }
                var results: [(Int, String)] = []
                for try await result in group { results.append(result) }
                return results.sorted { $0.0 < $1.0 }.map(\.1)
            }
            let items = uploaded.map { MessageMediaItem(url: $0, type: "image") }
            let text = caption?.trimmingCharacters(in: .whitespacesAndNewlines)
            let content = (text?.isEmpty ?? true) ? nil : text
            if ws.connectionState == .connected {
                var payload: [String: Any] = [
                    "conversationId": conversationId,
                    "messageType": MessageType.album.rawValue,
                    "mediaItems": items.map { ["url": $0.url, "type": $0.type] },
                ]
                if let content { payload["content"] = content }
                if let replyToMessageId { payload["replyToMessageId"] = replyToMessageId }
                if case .failure(let err) = await emitWithAck("send_message", payload) {
                    self.error = Bundle.app.loc(friendlyError(err))
                } else {
                    noteMessageSent()
                }
            } else {
                let msg = try await repository.sendMessage(
                    conversationId: conversationId, content: content, messageType: .album,
                    mediaUrl: items.first?.url, mediaItems: items,
                    replyToMessageId: replyToMessageId, token: token)
                messages.append(msg)
                noteMessageSent()
            }
        } catch {
            self.error = Bundle.app.loc("Failed to upload media")
        }
    }

    // MARK: - Meeting proposals

    /// Propose a meeting (title/location/starts_at/ends_at + a mandatory
    /// reminder) in this conversation. Prefers the socket (server fans out
    /// `new_message` to both sides, same as text/media); falls back to REST
    /// when disconnected, appending the result locally since no broadcast
    /// will arrive to add this bubble. `reminderOffset` is the raw preset key
    /// ("on_day"/"1_day_before"/"2_days_before"/"1_week_before"); `reminderAt`
    /// is the absolute instant computed client-side (`MeetingReminderOffset
    /// .reminderDate(before:)`) since there's no per-user timezone tracked server-side.
    func sendMeetingProposal(
        title: String, location: String?, startsAt: Date, endsAt: Date?,
        reminderOffset: String, reminderAt: Date
    ) async {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return }
        isSending = true
        defer { isSending = false }

        if ws.connectionState == .connected {
            let iso = ISO8601DateFormatter()
            var proposalPayload: [String: Any] = [
                "title": trimmedTitle,
                "startsAt": iso.string(from: startsAt),
                "reminderOffset": reminderOffset,
                "reminderAt": iso.string(from: reminderAt)
            ]
            if let location, !location.isEmpty { proposalPayload["location"] = location }
            if let endsAt { proposalPayload["endsAt"] = iso.string(from: endsAt) }
            let result = await emitWithAck("send_message", [
                "conversationId": conversationId,
                "messageType": "meeting",
                "meetingProposal": proposalPayload
            ])
            if case .failure(let err) = result {
                self.error = friendlyError(err)
            }
        } else {
            do {
                let msg = try await repository.sendMeetingProposal(
                    conversationId: conversationId, title: trimmedTitle, location: location,
                    startsAt: startsAt, endsAt: endsAt,
                    reminderOffset: reminderOffset, reminderAt: reminderAt, token: token
                )
                messages.append(msg)
            } catch {
                self.error = Bundle.app.loc("Failed to send meeting proposal")
            }
        }
    }

    /// Reschedule an existing meeting proposal (proposer only — the server clears
    /// prior RSVPs, and resets `reminder_sent_at` so the reminder re-arms against
    /// the new time). Prefers the socket (server fans out `meeting_proposal_updated`
    /// to both sides); falls back to REST when disconnected, applying the result
    /// locally since no broadcast will arrive for this bubble.
    func rescheduleMeeting(
        messageId: String, title: String, location: String?, startsAt: Date, endsAt: Date?,
        reminderOffset: String, reminderAt: Date
    ) async {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return }

        if ws.connectionState == .connected {
            let iso = ISO8601DateFormatter()
            var payload: [String: Any] = [
                "conversationId": conversationId,
                "messageId": messageId,
                "title": trimmedTitle,
                "startsAt": iso.string(from: startsAt),
                "reminderOffset": reminderOffset,
                "reminderAt": iso.string(from: reminderAt)
            ]
            payload["location"] = (location?.isEmpty == false) ? location! : NSNull()
            payload["endsAt"] = endsAt.map { iso.string(from: $0) } ?? NSNull()
            if case .failure(let err) = await emitWithAck("update_meeting_proposal", payload) {
                self.error = friendlyError(err)
            }
        } else {
            do {
                let proposal = try await repository.updateMeetingProposal(
                    conversationId: conversationId, messageId: messageId, title: trimmedTitle,
                    location: location, startsAt: startsAt, endsAt: endsAt,
                    reminderOffset: reminderOffset, reminderAt: reminderAt, token: token
                )
                if let i = messages.firstIndex(where: { $0.id == messageId }) {
                    messages[i].meetingProposal = proposal
                }
            } catch {
                self.error = Bundle.app.loc("Could not reschedule meeting")
            }
        }
    }

    /// Cancel a meeting proposal (proposer only). Socket-first with REST fallback,
    /// same pattern as `rescheduleMeeting`.
    func cancelMeeting(messageId: String) async {
        if ws.connectionState == .connected {
            let result = await emitWithAck("cancel_meeting_proposal", [
                "conversationId": conversationId,
                "messageId": messageId
            ])
            if case .failure(let err) = result {
                self.error = friendlyError(err)
            }
        } else {
            do {
                let proposal = try await repository.cancelMeetingProposal(
                    conversationId: conversationId, messageId: messageId, token: token
                )
                if let i = messages.firstIndex(where: { $0.id == messageId }) {
                    messages[i].meetingProposal = proposal
                }
            } catch {
                self.error = Bundle.app.loc("Could not cancel meeting")
            }
        }
    }

    // MARK: - Polls (group chats)

    /// Sends a poll to this group. REST only: the server broadcasts it as
    /// `new_message` like any message; the reply is added here too in case
    /// that echo arrives late.
    func sendPoll(question: String, options: [String], endsAt: Date?) async -> Bool {
        isSending = true
        defer { isSending = false }
        do {
            let message = try await repository.sendPoll(conversationId: conversationId, question: question,
                                                        options: options, endsAt: endsAt, token: token)
            if !messages.contains(where: { $0.id == message.id }) { messages.append(message) }
            return true
        } catch {
            self.error = friendlyError(error)
            return false
        }
    }

    /// Votes once on a poll — shown at once, undone if the server refuses.
    func votePoll(messageId: String, optionId: String) async {
        guard let i = messages.firstIndex(where: { $0.id == messageId }), let poll = messages[i].poll,
              poll.myOptionID(userId: currentUserId) == nil, !poll.hasEnded() else { return }
        messages[i].poll = poll.votedLocally(optionId: optionId, userId: currentUserId)
        do {
            let fresh = try await repository.votePoll(conversationId: conversationId, messageId: messageId,
                                                      optionId: optionId, token: token)
            if let j = messages.firstIndex(where: { $0.id == messageId }) { messages[j].poll = fresh }
        } catch {
            if let j = messages.firstIndex(where: { $0.id == messageId }) { messages[j].poll = poll }
            self.error = Bundle.app.loc("Couldn't vote, please try again")
        }
    }

    /// RSVP to a meeting proposal. Socket-first with REST fallback, mirroring
    /// `sendReaction`'s exact branching.
    func respondToMeeting(messageId: String, status: MeetingRsvpStatus) async {
        if ws.connectionState == .connected {
            let result = await emitWithAck("respond_meeting", [
                "conversationId": conversationId,
                "messageId": messageId,
                "status": status.rawValue
            ])
            if case .failure(let err) = result {
                self.error = friendlyError(err)
            }
        } else {
            do {
                let proposal = try await repository.respondToMeeting(
                    conversationId: conversationId, messageId: messageId, status: status.rawValue, token: token
                )
                if let i = messages.firstIndex(where: { $0.id == messageId }) {
                    messages[i].meetingProposal = proposal
                }
            } catch {
                self.error = Bundle.app.loc("Could not respond to meeting")
            }
        }
    }

    // MARK: - WebSocket setup

    func joinConversation() {
        guard !hasJoinedConversation else { return }
        hasJoinedConversation = true
        emitJoin()

        // After a socket reconnect: re-join the room (server-side membership is
        // lost on disconnect) AND re-fetch the message history — messages sent
        // while the socket was down never arrived as live `new_message` events,
        // so an emit-join alone would leave a silent gap.
        reconnectObserver = NotificationCenter.default.addObserver(
            forName: .webSocketDidReconnect, object: nil, queue: .main
        ) { [weak self] _ in
            self?.emitJoin()
            Task { @MainActor [weak self] in await self?.loadMessages() }
        }

        ws.on("new_message", tag: socketTag) { [weak self] payload in
            guard let self,
                  let msg = self.decodeMessage(payload),
                  msg.conversationId == self.conversationId else { return }
            if !self.messages.contains(where: { $0.id == msg.id }) {
                self.messages.append(msg)
                // Tell the sender this message has arrived — flips their bubble
                // from `.sent` to `.delivered` via the `message_delivered` echo.
                if msg.senderId != self.currentUserId {
                    self.ws.emit("message_delivered", [
                        "conversationId": self.conversationId,
                        "messageId": msg.id
                    ])
                }
            }
        }

        // The recipient's client confirmed receipt of one of my messages.
        // Reconciled against the real backend broadcast (`backend/index.js`'s
        // `message_delivered` handler): `{ conversationId, messageId, userId }`,
        // sent only to the sender's personal room. Appends the delivering
        // user's id to `deliveredTo`, idempotently (a duplicate delivered
        // event for an already-delivered message is a no-op).
        ws.on("message_delivered", tag: socketTag) { [weak self] payload in
            guard let self,
                  let dict = payload as? [String: Any],
                  let convId = (dict["conversation_id"] as? String) ?? (dict["conversationId"] as? String),
                  convId == self.conversationId,
                  let userId = dict["user_id"] as? String ?? dict["userId"] as? String else { return }
            let messageIds = self.receiptMessageIds(from: dict)
            for i in self.messages.indices where messageIds.contains(self.messages[i].id) {
                if !self.messages[i].deliveredTo.contains(userId) {
                    self.messages[i].deliveredTo.append(userId)
                }
            }
        }

        ws.on("user_typing", tag: socketTag) { [weak self] payload in
            guard let self,
                  let dict = payload as? [String: Any],
                  let userId = dict["userId"] as? String,
                  userId != self.currentUserId,
                  let isTyping = dict["isTyping"] as? Bool else { return }
            self.handleTyping(userId: userId, isTyping: isTyping)
        }

        // Someone (possibly me, from another device) read messages in this
        // conversation. Reconciled against the real backend broadcast
        // (`backend/index.js`'s `mark_read` handler): `{ conversationId, readBy }`
        // where `readBy` is the reading user's id (not `user_id`/`userId`, and
        // no message ids — `mark_read` is conversation-scoped, so every message
        // not sent by the reader is affected, matching `markRead()`'s "mark my
        // whole unread tail as read" semantics). Appends `readBy` to `readBy`
        // (and `deliveredTo`, since read implies delivered) for the affected
        // messages only — NOT a blanket flip of every message.
        ws.on("messages_read", tag: socketTag) { [weak self] payload in
            guard let self,
                  let dict = payload as? [String: Any],
                  let convId = (dict["conversation_id"] as? String) ?? (dict["conversationId"] as? String),
                  convId == self.conversationId,
                  let userId = (dict["readBy"] as? String) ?? (dict["read_by"] as? String)
                    ?? (dict["user_id"] as? String) ?? (dict["userId"] as? String) else { return }
            let scopedIds = self.receiptMessageIds(from: dict)
            for i in self.messages.indices {
                guard self.messages[i].senderId != userId else { continue }
                guard scopedIds.isEmpty || scopedIds.contains(self.messages[i].id) else { continue }
                if !self.messages[i].readBy.contains(userId) {
                    self.messages[i].readBy.append(userId)
                }
                if !self.messages[i].deliveredTo.contains(userId) {
                    self.messages[i].deliveredTo.append(userId)
                }
            }
        }

        ws.on("message_deleted", tag: socketTag) { [weak self] payload in
            guard let self,
                  let dict = payload as? [String: Any],
                  let convId = dict["conversation_id"] as? String,
                  convId == self.conversationId,
                  let messageId = dict["message_id"] as? String,
                  let i = self.messages.firstIndex(where: { $0.id == messageId }) else { return }
            self.messages[i].markDeleted()
            // Any OTHER message quoting this one via reply-preview would otherwise
            // keep showing stale content until the conversation reloads — patch its
            // embedded `repliedMessage` to the same "deleted" shape a fresh fetch
            // would already return (mirrors how `replyPreview` renders `isDeleted`).
            self.patchRepliedPreviews(forDeletedMessageId: messageId)
        }

        // A reaction was added/changed/removed on a message (either participant)
        ws.on("reaction_updated", tag: socketTag) { [weak self] payload in
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
        ws.on("meeting_proposal_updated", tag: socketTag) { [weak self] payload in
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
        ws.on("meeting_response_updated", tag: socketTag) { [weak self] payload in
            guard let self,
                  let dict = payload as? [String: Any],
                  let convId = dict["conversation_id"] as? String,
                  convId == self.conversationId,
                  let messageId = dict["message_id"] as? String,
                  let i = self.messages.firstIndex(where: { $0.id == messageId }),
                  let proposal = self.decodeMeetingProposal(dict) else { return }
            self.messages[i].meetingProposal = proposal
        }

        // Someone voted on a poll: new counts and voters.
        ws.on("poll_updated", tag: socketTag) { [weak self] payload in
            guard let self,
                  let dict = payload as? [String: Any],
                  dict["conversation_id"] as? String == self.conversationId,
                  let messageId = dict["message_id"] as? String,
                  let i = self.messages.firstIndex(where: { $0.id == messageId }),
                  let pollDict = dict["poll"],
                  let json = try? JSONSerialization.data(withJSONObject: pollDict),
                  let poll = try? JSONDecoder.makeISO8601().decode(ChatPoll.self, from: json) else { return }
            self.messages[i].poll = poll
        }

        // Shared settings (theme/nickname) changed by either participant.
        // The nickname-target match only applies in the 1:1 case — a group has
        // no single "other person" for `otherUserId` to compare against.
        ws.on("conversation_settings_updated", tag: socketTag) { [weak self] payload in
            guard let self,
                  let dict = payload as? [String: Any],
                  let convId = dict["conversation_id"] as? String,
                  convId == self.conversationId else { return }
            // Only touch the theme when the broadcast actually carries one — a
            // nickname-only update omits "theme", and blindly assigning
            // `dict["theme"] as? String` (nil) wiped the other participant's
            // chat theme.
            if dict.keys.contains("theme") {
                self.chatThemeId = dict["theme"] as? String
            }
            if !self.isGroup, let targetId = dict["nickname_target_id"] as? String, targetId == self.otherUserId {
                self.otherNickname = dict["nickname"] as? String
            }
        }

        // Group identity (name/photo) changed by the owner — refetch rather
        // than patch individual fields from the payload, since the exact
        // broadcast shape isn't pinned down; a refetch is resilient to that
        // and this is a low-frequency event.
        ws.on("group_updated", tag: socketTag) { [weak self] payload in
            guard let self, self.isGroup,
                  let dict = payload as? [String: Any],
                  let convId = dict["conversation_id"] as? String,
                  convId == self.conversationId else { return }
            Task { await self.loadSettings() }
        }

        // A member was added to this group — refetch the roster.
        ws.on("member_added", tag: socketTag) { [weak self] payload in
            guard let self, self.isGroup,
                  let dict = payload as? [String: Any],
                  let convId = dict["conversation_id"] as? String,
                  convId == self.conversationId else { return }
            Task { await self.loadSettings() }
        }

        // A message was pinned by any participant. The server broadcasts the
        // conversation's full current pin list (not a single row) — replace
        // wholesale rather than trying to merge one row in.
        ws.on("pin_added", tag: socketTag) { [weak self] payload in
            guard let self,
                  let dict = payload as? [String: Any],
                  let convId = dict["conversation_id"] as? String,
                  convId == self.conversationId,
                  let pins = self.decodePinnedMessages(dict["pins"]) else { return }
            self.pinnedMessages = pins
        }

        // A message was unpinned by any participant.
        ws.on("pin_removed", tag: socketTag) { [weak self] payload in
            guard let self,
                  let dict = payload as? [String: Any],
                  let convId = dict["conversation_id"] as? String,
                  convId == self.conversationId,
                  let messageId = dict["message_id"] as? String else { return }
            self.pinnedMessages.removeAll { $0.id == messageId }
        }

        // A member was removed from this group — refetch the roster, then check
        // (independent of the payload's exact shape) whether I'm still in it;
        // if not, I was the one removed and the conversation is no longer
        // accessible to me.
        ws.on("member_removed", tag: socketTag) { [weak self] payload in
            guard let self, self.isGroup,
                  let dict = payload as? [String: Any],
                  let convId = dict["conversation_id"] as? String,
                  convId == self.conversationId else { return }
            Task {
                await self.loadSettings()
                if !self.groupMembers.contains(where: { $0.id == self.currentUserId }) {
                    self.wasRemovedFromGroup = true
                }
            }
        }
    }

    func leaveConversation() {
        guard hasJoinedConversation else { return }
        hasJoinedConversation = false
        typingTasks.values.forEach { $0.cancel() }
        typingTasks = [:]
        if let reconnectObserver {
            NotificationCenter.default.removeObserver(reconnectObserver)
            self.reconnectObserver = nil
        }
        ws.emit("leave_conversation", conversationId)
        ws.off("new_message", tag: socketTag)
        ws.off("message_delivered", tag: socketTag)
        ws.off("user_typing",   tag: socketTag)
        ws.off("messages_read", tag: socketTag)
        ws.off("message_deleted", tag: socketTag)
        ws.off("reaction_updated", tag: socketTag)
        ws.off("meeting_proposal_updated", tag: socketTag)
        ws.off("meeting_response_updated", tag: socketTag)
        ws.off("poll_updated", tag: socketTag)
        ws.off("conversation_settings_updated", tag: socketTag)
        ws.off("group_updated", tag: socketTag)
        ws.off("member_added", tag: socketTag)
        ws.off("member_removed", tag: socketTag)
        ws.off("pin_added", tag: socketTag)
        ws.off("pin_removed", tag: socketTag)
    }

    /// Emits `join_conversation` for this conversation's room — factored out of
    /// `joinConversation()` so it can also be called after a socket reconnect
    /// without re-registering the listeners above (which are still live).
    private func emitJoin() {
        ws.emit("join_conversation", conversationId)
    }

    // MARK: - Recall

    /// Recall one of my own messages; update locally right away, the server will emit
    /// message_deleted to the other side.
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
            self.error = Bundle.app.loc("Could not recall message")
        }
    }

    // MARK: - Reactions

    /// React to a message (toggle off if re-tapping the same emoji, else set/replace).
    /// Prefers the socket (server also fans out `reaction_updated` to the other side);
    /// falls back to REST when disconnected, applying the result locally since no
    /// socket broadcast will arrive to update this bubble.
    func sendReaction(messageId: String, emoji: String) async {
        if ws.connectionState == .connected {
            let result = await emitWithAck("react_message", [
                "conversationId": conversationId,
                "messageId": messageId,
                "emoji": emoji
            ])
            if case .failure(let err) = result {
                self.error = friendlyError(err)
            }
        } else {
            do {
                let reactions = try await repository.react(
                    conversationId: conversationId, messageId: messageId, emoji: emoji, token: token
                )
                if let i = messages.firstIndex(where: { $0.id == messageId }) {
                    messages[i].reactions = reactions
                }
            } catch {
                self.error = Bundle.app.loc("Could not react to message")
            }
        }
    }

    // MARK: - Pinned messages
    // NOTE: socket payload/REST field names assumed per the Phase 4 plan's
    // working shape (parallel backend task not landed at write time) —
    // reconcile against the real backend once it lands. See `PinnedMessage`.

    /// Load this conversation's pinned messages (server caps at 10).
    func loadPins() async {
        do { pinnedMessages = try await repository.fetchPins(conversationId: conversationId, token: token) }
        catch {
            // Non-critical; chat stays usable without the pinned banner/menu state.
        }
    }

    /// Pin a message, optionally with an auto-delete expiry. Prefers the
    /// socket (server fans out `pin_added` to every participant); falls back
    /// to REST when disconnected, applying the result locally since no
    /// broadcast will arrive to update the banner/context-menu state.
    func pinMessage(_ messageId: String, expiresAt: Date?) async {
        if ws.connectionState == .connected {
            var payload: [String: Any] = ["conversationId": conversationId, "messageId": messageId]
            if let expiresAt { payload["expiresAt"] = ISO8601DateFormatter().string(from: expiresAt) }
            if case .failure(let err) = await emitWithAck("pin_message", payload) {
                self.error = friendlyError(err)
            }
        } else {
            do {
                try await repository.pinMessage(
                    conversationId: conversationId, messageId: messageId, expiresAt: expiresAt, token: token
                )
                // The create response is the raw pin row (no joined sender
                // name/content) — refetch for the properly-joined list.
                await loadPins()
            } catch {
                self.error = Bundle.app.loc("Could not pin message")
            }
        }
    }

    /// Unpin a message. Any participant may unpin (not owner-only). Socket-first
    /// with REST fallback, same pattern as `pinMessage`.
    func unpinMessage(_ messageId: String) async {
        if ws.connectionState == .connected {
            let result = await emitWithAck("unpin_message", [
                "conversationId": conversationId,
                "messageId": messageId
            ])
            if case .failure(let err) = result {
                self.error = friendlyError(err)
            }
        } else {
            do {
                try await repository.unpinMessage(conversationId: conversationId, messageId: messageId, token: token)
                pinnedMessages.removeAll { $0.id == messageId }
            } catch {
                self.error = Bundle.app.loc("Could not unpin message")
            }
        }
    }

    // MARK: - Mark read

    func markRead() {
        ws.emit("mark_read", ["conversationId": conversationId])
    }

    /// REST catch-up for delivery: flips any of my messages the other person
    /// received while offline from `.sent` to `.delivered`. The live path (while
    /// both sides are connected) is handled by the `message_delivered` socket
    /// event registered in `joinConversation()`.
    func markConversationDelivered() async {
        do {
            try await repository.markDelivered(conversationId: conversationId, token: token)
        } catch {
            // Non-critical; the live socket path still covers most cases.
        }
    }

    // MARK: - Typing indicator

    func sendTyping(_ isTyping: Bool) {
        ws.emit("typing", ["conversationId": conversationId, "isTyping": isTyping])
    }

    // MARK: - Helpers

    /// Inserts/removes `userId` from `typingUserIds`, with its own 3-second
    /// auto-clear timer independent of any other typing participant's timer.
    private func handleTyping(userId: String, isTyping: Bool) {
        typingTasks[userId]?.cancel()
        typingTasks[userId] = nil
        if isTyping {
            typingUserIds.insert(userId)
            typingTasks[userId] = Task {
                try? await Task.sleep(for: .seconds(3))
                if !Task.isCancelled { self.typingUserIds.remove(userId) }
            }
        } else {
            typingUserIds.remove(userId)
        }
    }

    /// Bridges `WebSocketClient.emit(...completion:)`'s callback into `async/await`
    /// so every socket-emit call site above can simply `await` the server's ack
    /// (or its rejection/timeout) instead of firing blind.
    private func emitWithAck(_ event: String, _ data: Any) async -> Result<Any?, Error> {
        await withCheckedContinuation { continuation in
            ws.emit(event, data) { result in
                continuation.resume(returning: result)
            }
        }
    }

    /// Patches every message whose embedded `repliedMessage` quotes `deletedId`
    /// so its preview reflects the deletion immediately, instead of staying stale
    /// until the conversation is reloaded from the server.
    private func patchRepliedPreviews(forDeletedMessageId deletedId: String) {
        for j in messages.indices {
            guard let replied = messages[j].repliedMessage,
                  replied.id == deletedId,
                  !replied.isDeleted else { continue }
            messages[j].repliedMessage = RepliedMessage(
                id: replied.id,
                senderId: replied.senderId,
                senderName: replied.senderName,
                messageType: replied.messageType,
                isDeleted: true,
                content: nil
            )
        }
    }

    /// Decodes the `pins` array from a `pin_added` socket payload — the
    /// server broadcasts the conversation's full current pin list on every
    /// change, not a single row.
    private func decodePinnedMessages(_ value: Any?) -> [PinnedMessage]? {
        guard let value else { return nil }
        guard let json = try? JSONSerialization.data(withJSONObject: value) else { return nil }
        return try? JSONDecoder.makeISO8601().decode([PinnedMessage].self, from: json)
    }

    /// Extracts the affected message id(s) from a `message_delivered`/
    /// `messages_read` receipt payload, tolerating a single `message_id`/
    /// `messageId` string or a `message_ids`/`messageIds` array — exact shape
    /// TBD until the parallel backend task lands (see the listener comments
    /// in `joinConversation()`). Returns an empty set when neither key is
    /// present, which callers treat as "no messages matched" rather than
    /// guessing a blanket scope.
    private func receiptMessageIds(from dict: [String: Any]) -> Set<String> {
        if let single = (dict["message_id"] as? String) ?? (dict["messageId"] as? String) {
            return [single]
        }
        if let many = (dict["message_ids"] as? [String]) ?? (dict["messageIds"] as? [String]) {
            return Set(many)
        }
        return []
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

    // MARK: - Block state & forwarding

    /// A block in either direction with the other 1:1 participant — the input
    /// bar is disabled while it holds. Refreshed on load and whenever
    /// `.userBlockStatusChanged` fires for that person.
    var isBlocked = false
    private(set) var isForwarding = false
    private let userRepository = UserRepository()

    func refreshBlockedState() async {
        guard let otherUserId else { return }
        let status = try? await userRepository.fetchBlockStatusDetailed(userId: otherUserId)
        isBlocked = status?.blockedEitherWay ?? isBlocked
    }

    /// Re-sends `message`'s content/media to another conversation. No re-upload:
    /// the server doesn't tie `media_url` to the original sender or conversation,
    /// so the URL is reused. Not threaded as a reply there — the original
    /// message doesn't exist in the target conversation.
    func forward(_ message: Message, to targetConversationId: String) async {
        guard !isForwarding else { return }
        isForwarding = true
        defer { isForwarding = false }
        _ = try? await repository.sendMessage(
            conversationId: targetConversationId,
            content: message.content,
            messageType: message.messageType,
            mediaUrl: message.mediaUrl,
            mediaItems: message.mediaItems,
            replyToMessageId: nil,
            voiceDurationSeconds: message.voiceDurationSeconds,
            voiceWaveform: message.voiceWaveform,
            token: token)
    }
}

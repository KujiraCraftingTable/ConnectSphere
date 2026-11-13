import Foundation
import Observation

@MainActor
@Observable
class ConversationListViewModel {

    var conversations: [Conversation] = []
    var isLoading = false
    var error: String?
    /// A swipe action the server refused. Shown as an alert over the list.
    var actionError: String?
    var unreadCount: Int = 0

    /// Accepted connections, used by the Spaces editor's people picker.
    var connections: [ConnectionItemDTO] = []
    var onlineUserIds: Set<String> = []
    /// People hidden from the people row in `hiddenMode` (their chats stay listed).
    private(set) var hiddenUserIds: Set<String> = []
    private var hiddenMode: String?

    // Cross-conversation search (name + message content)
    var searchResults: [ConversationSearchHit] = []
    var isSearching = false
    private var searchTask: Task<Void, Never>?

    /// People row under the search box: everyone with a 1:1 chat in the inbox,
    /// online first, then most recent message.
    var recentPeople: [Conversation] {
        inbox
            .filter { c in
                guard !c.isGroup, let id = c.otherUserId, !id.isEmpty else { return false }
                return !hiddenUserIds.contains(id)
            }
            .sorted { a, b in
                let (aOn, bOn) = (isOnline(a), isOnline(b))
                if aOn != bOn { return aOn }
                return (a.lastMessageAt ?? a.updatedAt) > (b.lastMessageAt ?? b.updatedAt)
            }
    }

    func isOnline(_ conversation: Conversation) -> Bool {
        guard let id = conversation.otherUserId else { return false }
        return onlineUserIds.contains(id)
    }

    private let repository = MessageRepository()
    private let connectionRepo = ConnectionRepository()
    private let userRepository = UserRepository()
    private let ws = WebSocketClient.shared

    init() {
        // Unhiding in Settings › Privacy brings the person back to the row at once.
        NotificationCenter.default.addObserver(forName: .hiddenContactsChanged, object: nil, queue: .main) { [weak self] note in
            guard let userId = note.userInfo?["userId"] as? String,
                  let mode = note.userInfo?["mode"] as? String,
                  let hidden = note.userInfo?["hidden"] as? Bool else { return }
            MainActor.assumeIsolated {
                guard let self, self.hiddenMode == mode else { return }
                if hidden { self.hiddenUserIds.insert(userId) } else { self.hiddenUserIds.remove(userId) }
            }
        }
    }

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
            self.error = friendlyError(error)
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

    // MARK: - Hidden contacts (people row)

    /// Errors keep the last known set: the row just shows everyone.
    func loadHiddenContacts(mode: String, token: String) async {
        guard let contacts = try? await repository.fetchHiddenContacts(mode: mode, token: token) else { return }
        hiddenMode = mode
        hiddenUserIds = Set(contacts.map(\.id))
    }

    /// Optimistic: the photo leaves the row at once and comes back if the server refuses.
    func hide(_ conversation: Conversation, mode: String, token: String) async {
        guard let userId = conversation.otherUserId, !userId.isEmpty else { return }
        hiddenMode = mode
        hiddenUserIds.insert(userId)
        do {
            try await repository.setContactHidden(userId: userId, hidden: true, mode: mode, token: token)
        } catch {
            hiddenUserIds.remove(userId)
            actionError = friendlyError(error)
        }
    }

    // MARK: - Inbox (main list vs archive)

    /// What the main list shows: not archived, not a waiting request; pinned first.
    var inbox: [Conversation] { conversations.filter { !$0.isArchived && $0.requestState != .waiting } }
    var archived: [Conversation] { conversations.filter { $0.isArchived && $0.requestState != .waiting } }
    /// Chats from people who aren't friends yet, until accepted.
    var waiting: [Conversation] { conversations.filter { $0.requestState == .waiting } }

    func accept(_ conversation: Conversation, token: String) async {
        await change(conversation.id, { $0.requestState = nil }) {
            try await repository.acceptRequest(conversationId: conversation.id, token: token)
        }
    }

    // MARK: - Swipe actions
    //
    // Each one updates the row at once, then asks the server; if the server
    // refuses, the old state comes back and the error is shown.

    func setPinned(_ conversation: Conversation, _ pinned: Bool, token: String) async {
        await change(conversation.id, { $0.isPinned = pinned }) {
            try await repository.setPinned(conversationId: conversation.id, pinned: pinned, token: token)
        }
    }

    func setArchived(_ conversation: Conversation, _ archived: Bool, token: String) async {
        await change(conversation.id, {
            $0.isArchived = archived
            if archived { $0.isPinned = false }
        }) {
            try await repository.setArchived(conversationId: conversation.id, archived: archived, token: token)
        }
    }

    func markRead(_ conversation: Conversation, token: String) async {
        guard conversation.hasUnread else { return }
        unreadCount = max(0, unreadCount - conversation.unreadCount)
        await change(conversation.id, { $0.unreadCount = 0 }) {
            try await repository.markRead(conversationId: conversation.id, token: token)
        }
    }

    /// Mute until turned back on, or unmute.
    func setMuted(_ conversation: Conversation, _ muted: Bool, token: String) async {
        await change(conversation.id, { $0.mutedUntil = muted ? .distantFuture : nil }) {
            try await repository.setMute(conversationId: conversation.id, minutes: muted ? -1 : nil, token: token)
        }
    }

    /// Clears the chat's history for me; it leaves the list until a new message arrives.
    func delete(_ conversation: Conversation, token: String) async {
        await remove(conversation) {
            try await repository.clearConversation(conversationId: conversation.id, token: token)
        }
    }

    func block(_ conversation: Conversation) async {
        guard let otherId = conversation.otherUserId else { return }
        await remove(conversation) { try await userRepository.blockUser(userId: otherId) }
    }

    private func change(_ id: String, _ edit: (inout Conversation) -> Void,
                        request: () async throws -> Void) async {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        let before = conversations
        edit(&conversations[index])
        sortPinnedFirst()
        do {
            try await request()
        } catch {
            conversations = before
            actionError = friendlyError(error)
        }
    }

    private func remove(_ conversation: Conversation, request: () async throws -> Void) async {
        let before = conversations
        conversations.removeAll { $0.id == conversation.id }
        do {
            try await request()
        } catch {
            conversations = before
            actionError = friendlyError(error)
        }
    }

    /// Same order as the server: pinned first, then most recent.
    private func sortPinnedFirst() {
        conversations.sort { a, b in
            if a.isPinned != b.isPinned { return a.isPinned }
            return a.updatedAt > b.updatedAt
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
        // A theme/nickname/accept note is a chat's newest item too.
        ws.on("conversation_event", tag: "conversationList") { [weak self] _ in
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
        ws.off("conversation_event", tag: "conversationList")
        ws.off("presence_snapshot", tag: "presence")
        ws.off("presence_update", tag: "presence")
    }

    // MARK: - Open conversation

    func openConversation(with otherUserId: String, mode: String, token: String) async throws -> String {
        return try await repository.openConversation(otherUserId: otherUserId, mode: mode, token: token)
    }

    // MARK: - Search

    /// Debounced cross-conversation search. Cancels any in-flight search so
    /// only the latest keystroke's request lands. An empty (or whitespace-only)
    /// query clears results immediately without a round trip.
    func search(query: String, mode: String, token: String) {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchResults = []
            isSearching = false
            return
        }
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            isSearching = true
            defer { isSearching = false }
            let results = (try? await repository.searchAll(mode: mode, query: trimmed, token: token)) ?? []
            guard !Task.isCancelled else { return }
            searchResults = results
        }
    }
}

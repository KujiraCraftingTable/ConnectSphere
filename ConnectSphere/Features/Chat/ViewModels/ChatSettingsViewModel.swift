import SwiftUI
import Observation

/// Backs the per-conversation settings screen: loads the settings snapshot and
/// performs nickname / theme / mute / clear mutations, plus media & search.
@MainActor
@Observable
class ChatSettingsViewModel {

    var settings: ConversationSettings?
    var isLoading = false
    var error: String?
    private(set) var isCreatingGroup = false

    // Media gallery
    var media: [ChatMediaItem] = []
    var isLoadingMedia = false

    // In-conversation search
    var searchResults: [Message] = []
    var isSearching = false

    // Pinned messages (settings-sheet-scoped list — `ChatViewModel` keeps its
    // own live-updated copy for the in-thread banner/context menu)
    var pinnedMessages: [PinnedMessage] = []
    var isLoadingPins = false

    private let conversationId: String
    private let token: String
    private let repository = MessageRepository()

    init(conversationId: String, token: String) {
        self.conversationId = conversationId
        self.token          = token
    }

    /// Whether the conversation is currently muted for me.
    var isMuted: Bool { settings?.isMuted ?? false }

    /// True when this conversation is a group (vs. 1:1).
    var isGroup: Bool { settings?.isGroup ?? false }

    /// True when the current user currently holds this group's owner role
    /// (ownership can transfer via promote, so this checks live role — not
    /// `groupCreatedBy`, which stays fixed to whoever created the group).
    /// Always false for 1:1 or before settings finish loading.
    func isOwner(currentUserId: String) -> Bool {
        settings?.members.first(where: { $0.id == currentUserId })?.isOwner ?? false
    }

    // MARK: - Load

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do { settings = try await repository.fetchSettings(conversationId: conversationId, token: token) }
        catch { self.error = Bundle.app.loc("Could not load settings") }
    }

    // MARK: - Mutations

    /// Save the shared nickname for the other person (empty string clears it).
    func saveNickname(_ nickname: String) async {
        let trimmed = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        do { settings = try await repository.updateNickname(conversationId: conversationId, nickname: trimmed.isEmpty ? nil : trimmed, token: token) }
        catch { self.error = Bundle.app.loc("Could not update nickname") }
    }

    /// Select the shared chat theme (nil resets to default).
    func selectTheme(_ id: String?) async {
        do { settings = try await repository.updateTheme(conversationId: conversationId, theme: id, token: token) }
        catch { self.error = Bundle.app.loc("Could not update theme") }
    }

    /// Set my mute preference, then refresh the snapshot.
    func setMute(minutes: Int?) async {
        do {
            _ = try await repository.setMute(conversationId: conversationId, minutes: minutes, token: token)
            await load()
        } catch { self.error = Bundle.app.loc("Could not update notifications") }
    }

    /// Rename the group (owner-only server-side).
    func renameGroup(_ name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            settings = try await repository.updateGroup(
                conversationId: conversationId, name: trimmed, avatarUrl: nil, avatarColor: nil, token: token
            )
        } catch { self.error = Bundle.app.loc("Could not rename group") }
    }

    /// Update the group's photo color swatch (owner-only server-side). The app
    /// doesn't have a photo-upload flow for chat groups yet, so this exposes
    /// only the color half of `PATCH .../group` — matches the "avatar_color"
    /// fallback every `ConversationPeer`/`ChatPeer` already renders when a
    /// group has no `avatar_url` photo.
    func updateGroupColor(_ color: String) async {
        do {
            settings = try await repository.updateGroup(
                conversationId: conversationId, name: nil, avatarUrl: nil, avatarColor: color, token: token
            )
        } catch { self.error = Bundle.app.loc("Could not update group photo") }
    }

    // MARK: - Media

    func loadMedia() async {
        isLoadingMedia = true
        defer { isLoadingMedia = false }
        do { media = try await repository.fetchMedia(conversationId: conversationId, token: token) }
        catch { self.error = Bundle.app.loc("Could not load media") }
    }

    // MARK: - Search

    func search(_ query: String) async {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { searchResults = []; return }
        isSearching = true
        defer { isSearching = false }
        do { searchResults = try await repository.searchMessages(conversationId: conversationId, query: q, token: token) }
        catch { self.error = Bundle.app.loc("Search failed") }
    }

    // MARK: - Pinned messages

    /// Load this conversation's pinned messages (server caps at 10).
    func loadPins() async {
        isLoadingPins = true
        defer { isLoadingPins = false }
        do { pinnedMessages = try await repository.fetchPins(conversationId: conversationId, token: token) }
        catch { self.error = Bundle.app.loc("Could not load pinned messages") }
    }

    /// Resolves a user id to a display name using the loaded settings
    /// snapshot (group roster, or the 1:1 other person). Returns nil if
    /// unresolvable — e.g. settings haven't loaded, or it's the current user
    /// (callers wanting "You" should check that against their own id first).
    func displayName(forUserId userId: String) -> String? {
        guard let settings else { return nil }
        if settings.isGroup {
            return settings.members.first(where: { $0.id == userId })?.displayName
        }
        return settings.otherUserId == userId ? (settings.otherUserNickname ?? settings.otherUserName) : nil
    }

    /// Unpin a message from this conversation. Any participant may unpin.
    /// Removes it from the local list immediately on success. Returns true on success.
    @discardableResult
    func unpinMessage(_ messageId: String) async -> Bool {
        do {
            try await repository.unpinMessage(conversationId: conversationId, messageId: messageId, token: token)
            pinnedMessages.removeAll { $0.id == messageId }
            return true
        } catch {
            self.error = Bundle.app.loc("Could not unpin message")
            return false
        }
    }

    // MARK: - Clear

    /// Clear the conversation on my side only. Returns true on success.
    func clearConversation() async -> Bool {
        do {
            try await repository.clearConversation(conversationId: conversationId, token: token)
            return true
        } catch {
            self.error = Bundle.app.loc("Could not delete messages")
            return false
        }
    }

    // MARK: - Block (1:1 only)

    private(set) var isBlocked = false
    var blockErrorMessage: String?
    private let userRepository = UserRepository()

    func loadBlockStatus(otherUserId: String) async {
        isBlocked = (try? await userRepository.fetchBlockStatus(userId: otherUserId)) ?? false
    }

    /// Blocks or unblocks; returns the new state on success (nil on failure,
    /// with `blockErrorMessage` set). Any open ChatView for this person
    /// refreshes live via `.userBlockStatusChanged`.
    func toggleBlock(otherUserId: String) async -> Bool? {
        do {
            if isBlocked {
                try await userRepository.unblockUser(userId: otherUserId)
            } else {
                try await userRepository.blockUser(userId: otherUserId)
            }
            isBlocked.toggle()
            NotificationCenter.default.post(name: .userBlockStatusChanged, object: nil, userInfo: ["userId": otherUserId])
            return isBlocked
        } catch {
            blockErrorMessage = friendlyError(error)
            return nil
        }
    }

    // MARK: - Group from this chat

    /// Makes a group of me, the person in this chat and the people picked
    /// (the server needs at least 3 people in total). Returns the new id.
    func createGroup(with otherUserId: String, plus memberIds: Set<String>, name: String?,
                     mode: String) async -> String? {
        isCreatingGroup = true
        defer { isCreatingGroup = false }
        do {
            return try await repository.createGroup(memberIds: [otherUserId] + memberIds.sorted(),
                                                    mode: mode, name: name, token: token)
        } catch {
            self.error = friendlyError(error)
            return nil
        }
    }
}

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

    // Media gallery
    var media: [ChatMediaItem] = []
    var isLoadingMedia = false

    // In-conversation search
    var searchResults: [Message] = []
    var isSearching = false

    private let conversationId: String
    private let token: String
    private let repository = MessageRepository()

    init(conversationId: String, token: String) {
        self.conversationId = conversationId
        self.token          = token
    }

    /// Whether the conversation is currently muted for me.
    var isMuted: Bool { settings?.isMuted ?? false }

    // MARK: - Load

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do { settings = try await repository.fetchSettings(conversationId: conversationId, token: token) }
        catch { self.error = "Could not load settings" }
    }

    // MARK: - Mutations

    /// Save the shared nickname for the other person (empty string clears it).
    func saveNickname(_ nickname: String) async {
        let trimmed = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        do { settings = try await repository.updateNickname(conversationId: conversationId, nickname: trimmed.isEmpty ? nil : trimmed, token: token) }
        catch { self.error = "Could not update nickname" }
    }

    /// Select the shared chat theme (nil resets to default).
    func selectTheme(_ id: String?) async {
        do { settings = try await repository.updateTheme(conversationId: conversationId, theme: id, token: token) }
        catch { self.error = "Could not update theme" }
    }

    /// Set my mute preference, then refresh the snapshot.
    func setMute(minutes: Int?) async {
        do {
            _ = try await repository.setMute(conversationId: conversationId, minutes: minutes, token: token)
            await load()
        } catch { self.error = "Could not update notifications" }
    }

    // MARK: - Media

    func loadMedia() async {
        isLoadingMedia = true
        defer { isLoadingMedia = false }
        do { media = try await repository.fetchMedia(conversationId: conversationId, token: token) }
        catch { self.error = "Could not load media" }
    }

    // MARK: - Search

    func search(_ query: String) async {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { searchResults = []; return }
        isSearching = true
        defer { isSearching = false }
        do { searchResults = try await repository.searchMessages(conversationId: conversationId, query: q, token: token) }
        catch { self.error = "Search failed" }
    }

    // MARK: - Clear

    /// Clear the conversation on my side only. Returns true on success.
    func clearConversation() async -> Bool {
        do {
            try await repository.clearConversation(conversationId: conversationId, token: token)
            return true
        } catch {
            self.error = "Could not delete messages"
            return false
        }
    }
}

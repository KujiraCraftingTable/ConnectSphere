import Foundation

/// What a share sheet passes on.
enum ShareTarget: Equatable {
    case post(String)
    case community(String)
}
import Observation

/// Sharing a post: picking chats (the most recent 20, or any chat from the
/// full list) and sending to them all with one Send, or reposting it to your
/// own Feed. The note typed at the top goes with either.
@MainActor
@Observable
final class SharePostViewModel {
    var comment = ""
    private(set) var isSharing = false
    private(set) var shareFailed = false

    /// The chats a post can go to, as the Messages screen orders them.
    private(set) var recipients: [Conversation] = []
    private(set) var isLoadingRecipients = false
    /// Chats picked to send to — tapping a chat only picks it; Send sends.
    private(set) var selected: Set<String> = []
    private(set) var isSending = false
    /// Some picked chats couldn't be sent to (they stay picked for a retry).
    private(set) var sendFailed = false
    /// The full list's search.
    var query = ""

    static let recentCount = 20

    private let repository = PostRepository()
    private let messages = MessageRepository()

    var recent: [Conversation] { Array(recipients.prefix(Self.recentCount)) }
    var searched: [Conversation] { FloatingChatAddViewModel.addable(recipients, query: query) }

    /// Accepted chats only (no Waiting requests), not archived, newest first —
    /// the same list the floating window's "+" offers.
    func loadRecipients(mode: String, token: String) async {
        isLoadingRecipients = true
        defer { isLoadingRecipients = false }
        if let all = try? await messages.fetchConversations(mode: mode, token: token) {
            recipients = FloatingChatAddViewModel.addable(all, query: "")
        }
    }

    func isSelected(_ conversation: Conversation) -> Bool { selected.contains(conversation.id) }

    func toggle(_ conversation: Conversation) {
        if selected.contains(conversation.id) { selected.remove(conversation.id) } else { selected.insert(conversation.id) }
    }

    /// Sends the post (or community), with the note, to every picked chat.
    /// True when all went through; chats that failed stay picked.
    func sendSelected(_ target: ShareTarget, token: String) async -> Bool {
        guard !selected.isEmpty else { return false }
        isSending = true
        sendFailed = false
        defer { isSending = false }
        let note = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        var failed: Set<String> = []
        for conversationId in selected {
            do {
                switch target {
                case .post(let id):
                    _ = try await messages.sendPost(conversationId: conversationId, postId: id, note: note, token: token)
                case .community(let id):
                    _ = try await messages.sendCommunity(conversationId: conversationId, communityId: id,
                                                         note: note, token: token)
                }
            } catch {
                failed.insert(conversationId)
            }
        }
        selected = failed
        sendFailed = !failed.isEmpty
        return failed.isEmpty
    }

    /// Posts it to your own Feed. Returns true on success. Sharing a share
    /// points at the original — the backend resolves that. A community goes
    /// to the feed of its own mode.
    func share(_ target: ShareTarget, mode: AppMode, token: String) async -> Bool {
        isSharing = true
        shareFailed = false
        defer { isSharing = false }
        let note = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            switch target {
            case .post(let id):
                _ = try await repository.sharePost(postId: id, content: note, mode: mode)
            case .community(let id):
                try await CommunityRepository().shareToFeed(communityId: id, note: note, token: token)
            }
            return true
        } catch {
            shareFailed = true
            return false
        }
    }
}

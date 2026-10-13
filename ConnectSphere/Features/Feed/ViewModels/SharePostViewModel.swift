import Foundation
import Observation

/// Sharing a post: sending it straight into chats (the most recent 20, or
/// any chat from the full list), and reposting it to your own Feed. The note
/// typed at the top goes with either.
@MainActor
@Observable
final class SharePostViewModel {
    var comment = ""
    private(set) var isSharing = false
    private(set) var shareFailed = false

    /// Where a send to one chat stands.
    enum SendState: Equatable {
        case sending
        case sent(messageId: String)
        case failed
    }

    /// The chats a post can go to, as the Messages screen orders them.
    private(set) var recipients: [Conversation] = []
    private(set) var isLoadingRecipients = false
    private(set) var sendStates: [String: SendState] = [:]
    /// Chats whose send can still be taken back (for a few seconds).
    private(set) var undoable: Set<String> = []
    /// The full list's search.
    var query = ""

    static let recentCount = 20
    static let undoWindow: Duration = .seconds(5)

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

    /// Sends the post into `conversation` at once; the avatar shows "Sent".
    func send(postId: String, to conversation: Conversation, token: String) async {
        switch sendStates[conversation.id] {
        case .sending, .sent: return
        default: break
        }
        sendStates[conversation.id] = .sending
        do {
            let message = try await messages.sendPost(
                conversationId: conversation.id, postId: postId,
                note: comment.trimmingCharacters(in: .whitespacesAndNewlines), token: token)
            sendStates[conversation.id] = .sent(messageId: message.id)
            undoable.insert(conversation.id)
            Task {
                try? await Task.sleep(for: Self.undoWindow)
                undoable.remove(conversation.id)
            }
        } catch {
            sendStates[conversation.id] = .failed
        }
    }

    /// Takes a just-sent post back out of the chat (unsend).
    func undo(_ conversation: Conversation, token: String) async {
        guard case .sent(let messageId) = sendStates[conversation.id], undoable.contains(conversation.id) else { return }
        undoable.remove(conversation.id)
        do {
            try await messages.recallMessage(conversationId: conversation.id, messageId: messageId, token: token)
            sendStates[conversation.id] = nil
        } catch {
            sendStates[conversation.id] = .sent(messageId: messageId)
        }
    }

    /// Reposts to your own Feed. Returns true on success. Sharing a share
    /// points at the original — the backend resolves that.
    func share(postId: String, mode: AppMode) async -> Bool {
        isSharing = true
        shareFailed = false
        defer { isSharing = false }
        do {
            _ = try await repository.sharePost(postId: postId,
                                               content: comment.trimmingCharacters(in: .whitespacesAndNewlines),
                                               mode: mode)
            return true
        } catch {
            shareFailed = true
            return false
        }
    }
}

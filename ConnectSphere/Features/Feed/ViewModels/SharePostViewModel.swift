import Foundation

/// What a share sheet passes on.
enum ShareTarget: Equatable {
    case post(String)
    case community(String)
}
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

    /// Sends the post (or community) into `conversation` at once; the avatar shows "Sent".
    func send(_ target: ShareTarget, to conversation: Conversation, token: String) async {
        switch sendStates[conversation.id] {
        case .sending, .sent: return
        default: break
        }
        sendStates[conversation.id] = .sending
        do {
            let note = comment.trimmingCharacters(in: .whitespacesAndNewlines)
            let message: Message
            switch target {
            case .post(let id):
                message = try await messages.sendPost(conversationId: conversation.id, postId: id, note: note, token: token)
            case .community(let id):
                message = try await messages.sendCommunity(conversationId: conversation.id, communityId: id,
                                                           note: note, token: token)
            }
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

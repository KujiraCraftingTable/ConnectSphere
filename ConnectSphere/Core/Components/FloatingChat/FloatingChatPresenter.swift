import SwiftUI
import Observation

/// One conversation in the floating chat window — its own already-joined
/// `ChatViewModel` and its per-chat state. `id` = conversationId, so a
/// conversation is in the window at most once.
@MainActor
@Observable
final class FloatingBubbleState: Identifiable {
    let id: String
    let peer: ChatPeer
    let otherUserLocation: String?
    let currentUserId: String
    let token: String
    let viewModel: ChatViewModel

    /// Single-tap state — raises the keyboard and docks
    /// `FloatingChatComposerBar` above it for this chat.
    var isComposing = false
    /// Unsent composer text. Lives here rather than in the composer view so it
    /// survives the bar being dismissed and reopened, and so each chat keeps
    /// its own draft.
    var draftText = ""
    /// When the user last looked at or used this chat — the one with the
    /// oldest gives way when a fifth chat is floated.
    var lastUsed = Date()
    /// The newest message the user has seen here: set when the chat is
    /// floated and each time its card is tapped. Messages arriving later are
    /// unread until the next tap — merely being on screen doesn't count.
    var seenMessageID: String?

    init(conversationId: String, peer: ChatPeer, otherUserLocation: String?,
         currentUserId: String, token: String, viewModel: ChatViewModel) {
        self.id = conversationId
        self.peer = peer
        self.otherUserLocation = otherUserLocation
        self.currentUserId = currentUserId
        self.token = token
        self.viewModel = viewModel
        self.seenMessageID = viewModel.messages.last?.id
    }

    /// Messages from others since `seenMessageID`.
    var unreadCount: Int {
        let messages = viewModel.messages
        let start = seenMessageID.flatMap { id in messages.lastIndex { $0.id == id } }.map { $0 + 1 } ?? 0
        guard start < messages.count else { return 0 }
        return messages[start...].filter { !$0.isOwn(userId: currentUserId) && !$0.isDeleted }.count
    }
}

/// The side of the screen a stashed window is tucked into.
enum FloatingChatStashEdge: Equatable {
    case leading, trailing
}

/// App-wide presenter for the floating chat window — lets the user keep up
/// to four conversations open (still receiving and able to send) while
/// browsing any other tab, the way Android's chat bubbles work, scoped to
/// staying inside this app (iOS has no system-level overlay API a
/// third-party app can draw outside its own UI). The chats share one window
/// and are swiped through; the window can be stashed off a side edge like
/// Apple's picture-in-picture.
///
/// One instance is injected via `.environment` from `ConnectSphereApp` and
/// rendered by `MainTabView`'s overlay — same shape as `UndoToastPresenter`/
/// `UndoToastView`, which is what makes it survive tab switches (`MainTabView`
/// itself is never rebuilt when the selected tab changes).
///
/// Each chat owns its own `ChatViewModel`, re-tagged to
/// `"chatBubble-<conversationId>"` (see `ChatViewModel.retag(to:)`) so its
/// socket listeners keep running independently of the other floating chats,
/// or a plain `"chat"`-tagged full `ChatView`.
@MainActor
@Observable
final class FloatingChatPresenter {
    /// Android's limit: more than four chats in one window stops being glanceable.
    static let maxChats = 4

    /// In swipe order, left to right.
    private(set) var bubbles: [FloatingBubbleState] = []
    /// The chat the window shows.
    private(set) var activeID: String?
    /// The window's centre in the overlay's coordinate space; `nil` until the
    /// overlay places it on first appearance.
    var windowPosition: CGPoint?
    /// Set while the window is tucked off a side edge, leaving only its tab.
    private(set) var stashEdge: FloatingChatStashEdge?
    /// The one video playing in the window — at most one at a time.
    var playingVideoID: String?
    /// Set by `restore(_:)` — drives a root-level `.fullScreenCover` in
    /// `MainTabView` back into a full `ChatView`, regardless of which tab is
    /// currently active. Cleared automatically when that cover is dismissed
    /// (native swipe, or `ChatView`'s own shrink action re-minimizing it).
    var restoringBubble: FloatingBubbleState?
    /// Top edge of the docked composer bar in global coordinates, reported by
    /// `FloatingChatComposerBar` as it appears and as the keyboard animates.
    /// The overlay lifts the window just far enough to clear this, so nothing
    /// here has to guess a keyboard height. `nil` while no bar is on screen.
    var composerTopY: CGFloat?

    var isStashed: Bool { stashEdge != nil }

    var active: FloatingBubbleState? {
        bubbles.first { $0.id == activeID } ?? bubbles.last
    }

    var activeIndex: Int? {
        guard let active else { return nil }
        return bubbles.firstIndex { $0.id == active.id }
    }

    /// Unread messages in the chats to the left / right of the one showing.
    var unreadBefore: Int {
        guard let i = activeIndex else { return 0 }
        return bubbles[..<i].reduce(0) { $0 + $1.unreadCount }
    }

    var unreadAfter: Int {
        guard let i = activeIndex else { return 0 }
        return bubbles[(i + 1)...].reduce(0) { $0 + $1.unreadCount }
    }

    var totalUnread: Int { bubbles.reduce(0) { $0 + $1.unreadCount } }

    /// The one chat currently composing, if any — `toggleComposing` keeps
    /// this exclusive, so the overlay renders a single composer bar for it.
    var composingBubble: FloatingBubbleState? {
        bubbles.first { $0.isComposing }
    }

    /// Full `ChatView`s currently on screen. A count, not a flag: one chat can
    /// appear before the previous one's `onDisappear` fires (chat → chat).
    private var visibleFullChats = 0
    /// The window stays alive but out of sight while a full chat is open — it'd
    /// otherwise sit on top of its messages and composer.
    var isHiddenByFullChat: Bool { visibleFullChats > 0 }

    /// Called by `ChatView` as it appears, *before* it joins its conversation.
    /// A floating chat for that same conversation is closed outright: two live
    /// views of one chat is redundant, and worse, they share one socket —
    /// whichever leaves last emits `leave_conversation` and silently kicks the
    /// other out of the room. Closing first means this leave lands before the
    /// new join. The other floating chats are only hidden, and return when the
    /// full chat closes.
    func fullChatDidAppear(conversationId: String) {
        if let same = bubbles.first(where: { $0.id == conversationId }) {
            close(same)
        }
        dismissAllComposing()
        playingVideoID = nil
        visibleFullChats += 1
    }

    /// Paired with `fullChatDidAppear` from `ChatView.onDisappear`.
    func fullChatDidDisappear() {
        visibleFullChats = max(0, visibleFullChats - 1)
    }

    /// Whether `conversationId` is already in the window.
    func hasBubble(for conversationId: String) -> Bool {
        bubbles.contains { $0.id == conversationId }
    }

    /// Floats a conversation's already-loaded `ChatView`/`ChatViewModel` into
    /// the window and shows it. Re-tags the view model's socket listeners (see
    /// `ChatViewModel.retag(to:)`) rather than tearing them down and
    /// rebuilding from scratch, so no message history is lost and no extra
    /// fetch happens. When four chats are already floating, the one used
    /// longest ago is closed to make room — returned, so the caller can say so.
    @discardableResult
    func minimize(conversationId: String, peer: ChatPeer, otherUserLocation: String?,
                  currentUserId: String, token: String, viewModel: ChatViewModel) -> FloatingBubbleState? {
        stashEdge = nil
        if let existing = bubbles.first(where: { $0.id == conversationId }) {
            activate(existing)
            return nil
        }
        var evicted: FloatingBubbleState?
        if bubbles.count >= Self.maxChats, let oldest = bubbles.min(by: { $0.lastUsed < $1.lastUsed }) {
            evicted = oldest
            close(oldest)
        }
        viewModel.retag(to: "chatBubble-\(conversationId)")
        let bubble = FloatingBubbleState(
            conversationId: conversationId, peer: peer, otherUserLocation: otherUserLocation,
            currentUserId: currentUserId, token: token, viewModel: viewModel
        )
        bubbles.append(bubble)
        activate(bubble)
        return evicted
    }

    /// Shows `bubble` in the window (a swipe, an edge count, a new chat). Any
    /// reply bar closes and the playing video stops — both belonged to the
    /// chat being left.
    func activate(_ bubble: FloatingBubbleState) {
        guard bubble.id != activeID else { return }
        for other in bubbles where other.id != bubble.id { other.isComposing = false }
        activeID = bubble.id
        bubble.lastUsed = Date()
        playingVideoID = nil
    }

    /// Shows the chat `step` places to the left (negative) or right.
    func activateNeighbour(_ step: Int) {
        guard let i = activeIndex, bubbles.indices.contains(i + step) else { return }
        activate(bubbles[i + step])
    }

    /// The user tapped the chat: everything in it now counts as seen, here
    /// and for the sender (`mark_read`).
    func markSeen(_ bubble: FloatingBubbleState) {
        bubble.lastUsed = Date()
        let latest = bubble.viewModel.messages.last?.id
        guard latest != bubble.seenMessageID || bubble.unreadCount > 0 else { return }
        bubble.seenMessageID = latest
        bubble.viewModel.markRead()
    }

    /// Closes a chat without restoring — tears down its socket listeners
    /// entirely (the conversation is no longer live anywhere). The window
    /// moves to a neighbour; closing the last one removes the window.
    func close(_ bubble: FloatingBubbleState) {
        guard let index = bubbles.firstIndex(where: { $0.id == bubble.id }) else { return }
        bubble.viewModel.leaveConversation()
        bubbles.remove(at: index)
        if activeID == bubble.id {
            activeID = bubbles.isEmpty ? nil : bubbles[min(index, bubbles.count - 1)].id
            playingVideoID = nil
        }
        if bubbles.isEmpty {
            stashEdge = nil
            windowPosition = nil
        }
    }

    /// Tucks the window off `edge`, leaving its tab; any reply bar closes and
    /// the video stops.
    func stash(to edge: FloatingChatStashEdge) {
        dismissAllComposing()
        playingVideoID = nil
        stashEdge = edge
    }

    func unstash() {
        stashEdge = nil
    }

    /// Toggles `bubble`'s inline-compose affordance, closing any other
    /// chat's first — the on-screen keyboard is a single, device-wide
    /// resource, so only one chat composes at a time.
    func toggleComposing(_ bubble: FloatingBubbleState) {
        let opening = !bubble.isComposing
        for other in bubbles where other.id != bubble.id { other.isComposing = false }
        bubble.isComposing = opening
    }

    /// Closes every chat's compose affordance — used by the overlay's
    /// tap-outside catcher.
    func dismissAllComposing() {
        for bubble in bubbles { bubble.isComposing = false }
    }

    /// Removes a chat from the window and hands its still-live
    /// `ChatViewModel` to a root-level full-screen `ChatView` — no re-fetch,
    /// no re-join; the socket listeners registered under the bubble's tag
    /// just keep running uninterrupted.
    func restore(_ bubble: FloatingBubbleState) {
        guard let index = bubbles.firstIndex(where: { $0.id == bubble.id }) else { return }
        bubbles.remove(at: index)
        if activeID == bubble.id {
            activeID = bubbles.isEmpty ? nil : bubbles[min(index, bubbles.count - 1)].id
        }
        playingVideoID = nil
        restoringBubble = bubble
    }
}

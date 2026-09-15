import SwiftUI
import Observation

/// One active floating "chat head" — its own already-joined `ChatViewModel`,
/// current drag position, and mini-UI state. `id` = conversationId, so at
/// most one bubble can exist per conversation at a time.
@MainActor
@Observable
final class FloatingBubbleState: Identifiable {
    let id: String
    let peer: ChatPeer
    let otherUserLocation: String?
    let currentUserId: String
    let token: String
    let viewModel: ChatViewModel

    /// Last drag position (bubble's center), in the overlay's coordinate
    /// space. `nil` until `FloatingChatOverlay` assigns an initial
    /// cascade-spawn position on first render (Phase 2+ then owns updates
    /// via drag).
    var position: CGPoint?
    /// Single-tap state — shows an inline compose affordance (Phase 4).
    var isComposing = false

    init(conversationId: String, peer: ChatPeer, otherUserLocation: String?,
         currentUserId: String, token: String, viewModel: ChatViewModel) {
        self.id = conversationId
        self.peer = peer
        self.otherUserLocation = otherUserLocation
        self.currentUserId = currentUserId
        self.token = token
        self.viewModel = viewModel
    }
}

/// App-wide presenter for floating "chat head" mini windows — lets the user
/// keep a conversation open (still receiving and able to send) while
/// browsing any other tab, the way Messenger's chat heads work, scoped to
/// staying inside this app (iOS has no system-level overlay API a
/// third-party app can draw outside its own UI).
///
/// One instance is injected via `.environment` from `ConnectSphereApp` and
/// rendered by `MainTabView`'s overlay — same shape as `UndoToastPresenter`/
/// `UndoToastView`, which is what makes it survive tab switches (`MainTabView`
/// itself is never rebuilt when the selected tab changes).
///
/// Each bubble owns its own `ChatViewModel`, re-tagged to
/// `"chatBubble-<conversationId>"` (see `ChatViewModel.retag(to:)`) so its
/// socket listeners keep running independently of whichever other bubbles,
/// or a plain `"chat"`-tagged full `ChatView`, are also active.
@MainActor
@Observable
final class FloatingChatPresenter {
    private(set) var bubbles: [FloatingBubbleState] = []
    /// Set by `restore(_:)` — drives a root-level `.fullScreenCover` in
    /// `MainTabView` back into a full `ChatView`, regardless of which tab is
    /// currently active. Cleared automatically when that cover is dismissed
    /// (native swipe, or `ChatView`'s own shrink action re-minimizing it).
    var restoringBubble: FloatingBubbleState?

    /// Whether `conversationId` already has an active bubble — callers (e.g.
    /// a conversation row tap) can check this to bring the existing bubble
    /// forward instead of opening a second, redundant live view.
    func hasBubble(for conversationId: String) -> Bool {
        bubbles.contains { $0.id == conversationId }
    }

    /// Minimizes a conversation's already-loaded `ChatView`/`ChatViewModel`
    /// into a floating bubble. Re-tags the view model's socket listeners
    /// (see `ChatViewModel.retag(to:)`) rather than tearing them down and
    /// rebuilding from scratch, so no message history is lost and no extra
    /// fetch happens.
    @discardableResult
    func minimize(conversationId: String, peer: ChatPeer, otherUserLocation: String?,
                  currentUserId: String, token: String, viewModel: ChatViewModel) -> FloatingBubbleState {
        if let existing = bubbles.first(where: { $0.id == conversationId }) {
            bringToFront(existing)
            return existing
        }
        viewModel.retag(to: "chatBubble-\(conversationId)")
        let bubble = FloatingBubbleState(
            conversationId: conversationId, peer: peer, otherUserLocation: otherUserLocation,
            currentUserId: currentUserId, token: token, viewModel: viewModel
        )
        bubbles.append(bubble)
        return bubble
    }

    /// Brings a bubble to the front — last in the array renders topmost in
    /// the overlay's `ZStack`.
    func bringToFront(_ bubble: FloatingBubbleState) {
        guard let idx = bubbles.firstIndex(where: { $0.id == bubble.id }), idx != bubbles.count - 1 else { return }
        bubbles.remove(at: idx)
        bubbles.append(bubble)
    }

    /// Closes a bubble without restoring — tears down its socket listeners
    /// entirely (the conversation is no longer live anywhere).
    func close(_ bubble: FloatingBubbleState) {
        bubble.viewModel.leaveConversation()
        bubbles.removeAll { $0.id == bubble.id }
    }

    /// Toggles `bubble`'s inline-compose affordance, closing any other
    /// bubble's first — the on-screen keyboard is a single, device-wide
    /// resource, so only one bubble composes at a time.
    func toggleComposing(_ bubble: FloatingBubbleState) {
        let opening = !bubble.isComposing
        for other in bubbles where other.id != bubble.id { other.isComposing = false }
        bubble.isComposing = opening
        if opening { bringToFront(bubble) }
    }

    /// Closes every bubble's compose affordance — used by the overlay's
    /// tap-outside catcher.
    func dismissAllComposing() {
        for bubble in bubbles { bubble.isComposing = false }
    }

    /// Removes a bubble from the floating list and hands its still-live
    /// `ChatViewModel` to a root-level full-screen `ChatView` — no re-fetch,
    /// no re-join; the socket listeners registered under the bubble's tag
    /// just keep running uninterrupted.
    func restore(_ bubble: FloatingBubbleState) {
        bubbles.removeAll { $0.id == bubble.id }
        restoringBubble = bubble
    }
}

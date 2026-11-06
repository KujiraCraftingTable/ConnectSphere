import SwiftUI

/// Messenger-style swipe-to-reply: drag a message sideways, away from its own
/// edge, past a threshold, and let go to reply to it. Their messages (left
/// side) drag rightwards; your own (right side) drag leftwards.
struct SwipeToReplyModifier: ViewModifier {
    /// `1` drags rightwards (their messages), `-1` leftwards (your own).
    let direction: CGFloat
    /// Off for unsent messages and blocked chats. The same cases the
    /// long-press "Reply" item excludes, or where the composer is disabled.
    let isEnabled: Bool
    let onReply: () -> Void

    @Environment(\.appBundle) private var bundle
    @State private var offset: CGFloat = 0
    /// Locked on the first movement of each drag, so a mostly-vertical drag
    /// stays a scroll and never nudges the bubble sideways halfway through.
    @State private var lockedAxis: Axis?
    @State private var isPastThreshold = false

    private let threshold: CGFloat = 60
    private let maxTravel: CGFloat = 80

    func body(content: Content) -> some View {
        ZStack(alignment: direction > 0 ? .leading : .trailing) {
            // Stays put at the row's edge while the bubble slides off it.
            replyIcon
            content.offset(x: offset)
        }
        // Simultaneous, not `.gesture`: inside a ScrollView an exclusive
        // DragGesture swallows vertical scrolling (iOS 18+), and the long-press
        // context menu has to keep working too. `.subviews` switches only this
        // gesture off while the bubble's own buttons keep theirs.
        .simultaneousGesture(drag, including: isEnabled ? .all : .subviews)
        .sensoryFeedback(.impact(weight: .light), trigger: isPastThreshold) { old, new in !old && new }
        .accessibilityAction(named: Text("Reply", bundle: bundle)) {
            if isEnabled { onReply() }
        }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { value in
                let dx = value.translation.width
                let dy = value.translation.height
                if lockedAxis == nil {
                    lockedAxis = abs(dx) > abs(dy) * 1.5 ? .horizontal : .vertical
                }
                guard lockedAxis == .horizontal else { return }
                // Only the allowed direction moves the bubble.
                let travel = max(0, dx * direction)
                offset = rubberBanded(travel) * direction
                isPastThreshold = travel >= threshold
            }
            .onEnded { _ in
                if lockedAxis == .horizontal && isPastThreshold { onReply() }
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { offset = 0 }
                lockedAxis = nil
                isPastThreshold = false
            }
    }

    /// Follows the finger 1:1 up to the threshold, then resists, capped at
    /// `maxTravel` so a long drag can't throw the bubble across the screen.
    private func rubberBanded(_ travel: CGFloat) -> CGFloat {
        guard travel > threshold else { return travel }
        return min(maxTravel, threshold + (travel - threshold) * 0.3)
    }

    private var replyIcon: some View {
        let progress = min(1, abs(offset) / threshold)
        return Image(systemName: "arrowshape.turn.up.left.fill")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 32, height: 32)
            .background(.thinMaterial, in: Circle())
            .scaleEffect(0.6 + 0.4 * progress)
            .opacity(progress)
            .padding(.horizontal, 16)
            .accessibilityHidden(true)
    }
}

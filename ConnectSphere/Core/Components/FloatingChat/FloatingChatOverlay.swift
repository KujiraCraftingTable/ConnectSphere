import SwiftUI

extension View {
    /// Attaches every active floating chat bubble from `presenter`, freely
    /// positioned (each bubble owns its own `position`, draggable — see
    /// `FloatingChatBubbleView`) rather than pinned to a corner — put this on
    /// a screen-level view (see `MainTabView`), the same way
    /// `.undoToastOverlay(_:)` is.
    func floatingChatOverlay(_ presenter: FloatingChatPresenter) -> some View {
        overlay {
            GeometryReader { geo in
                ForEach(Array(presenter.bubbles.enumerated()), id: \.element.id) { index, bubble in
                    FloatingChatBubbleView(bubble: bubble, presenter: presenter, containerSize: geo.size)
                        .position(bubble.position ?? FloatingChatLayout.defaultSpawn(index: index, in: geo.size))
                        .zIndex(Double(index))
                        .onAppear {
                            if bubble.position == nil {
                                bubble.position = FloatingChatLayout.defaultSpawn(index: index, in: geo.size)
                            }
                        }
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: bubble.position)
                }
            }
            .allowsHitTesting(!presenter.bubbles.isEmpty)
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: presenter.bubbles.map(\.id))
        }
    }
}

/// Shared sizing/placement math for floating bubbles — spawn position here,
/// edge-snap clamping in `FloatingChatBubbleView`. Kept in one place so the
/// two stay consistent as bubble size/margins are tuned.
enum FloatingChatLayout {
    static let bubbleWidth: CGFloat = 132
    static var bubbleHeight: CGFloat { bubbleWidth * 16 / 9 }
    /// How far a newly-spawned bubble cascades from the previous one so a
    /// second bubble doesn't land exactly on top of the first (Phase 3).
    static let cascadeStep: CGFloat = 18

    static func defaultSpawn(index: Int, in container: CGSize) -> CGPoint {
        let margin: CGFloat = bubbleWidth / 2 + 12
        let bottomGutter: CGFloat = bubbleHeight / 2 + 150   // clears the tab bar
        return CGPoint(
            x: container.width - margin - CGFloat(index) * cascadeStep,
            y: container.height - bottomGutter - CGFloat(index) * cascadeStep
        )
    }

    /// Snaps `point` to whichever horizontal edge it's closer to, clamping
    /// vertically so the bubble always stays fully on-screen.
    static func snapped(_ point: CGPoint, in container: CGSize) -> CGPoint {
        guard container.width > 0, container.height > 0 else { return point }
        let halfWidth = bubbleWidth / 2
        let halfHeight = bubbleHeight / 2
        let edgeMargin: CGFloat = 10
        let minX = halfWidth + edgeMargin
        let maxX = max(minX, container.width - halfWidth - edgeMargin)
        let minY = halfHeight + 60   // clear the status bar / nav area
        let maxY = max(minY, container.height - halfHeight - 130)   // clear the tab bar
        let snappedX = point.x < container.width / 2 ? minX : maxX
        let clampedY = min(max(point.y, minY), maxY)
        return CGPoint(x: snappedX, y: clampedY)
    }
}

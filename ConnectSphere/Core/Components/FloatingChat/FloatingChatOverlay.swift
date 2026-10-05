import SwiftUI

extension View {
    /// Attaches every active floating chat bubble from `presenter`, freely
    /// positioned (each bubble owns its own `position`, draggable — see
    /// `FloatingChatBubbleView`) rather than pinned to a corner — put this on
    /// a screen-level view (see `MainTabView`), the same way
    /// `.undoToastOverlay(_:)` is.
    func floatingChatOverlay(_ presenter: FloatingChatPresenter) -> some View {
        overlay {
            ZStack {
                GeometryReader { geo in
                    // Tap-outside-to-dismiss-keyboard catcher — only present
                    // (and only hit-testable) while some bubble is composing;
                    // sits behind every bubble so tapping a bubble itself is
                    // unaffected, and behind the composer bar (a later sibling
                    // of this layer) so tapping the field doesn't dismiss it.
                    if presenter.composingBubble != nil {
                        Color.clear
                            .contentShape(Rectangle())
                            .frame(width: geo.size.width, height: geo.size.height)
                            .onTapGesture { presenter.dismissAllComposing() }
                    }
                    ForEach(Array(presenter.bubbles.enumerated()), id: \.element.id) { index, bubble in
                        let center = bubble.position ?? FloatingChatLayout.defaultSpawn(index: index, in: geo.size)
                        let lift: CGFloat = {
                            guard bubble.isComposing, let top = presenter.composerTopY else { return 0 }
                            return FloatingChatLayout.composeLift(cardCenterY: center.y, composerTopY: top)
                        }()
                        FloatingChatBubbleView(bubble: bubble, presenter: presenter, containerSize: geo.size)
                            .position(center)
                            .offset(y: -lift)
                            .zIndex(Double(index))
                            .onAppear {
                                if bubble.position == nil {
                                    bubble.position = FloatingChatLayout.defaultSpawn(index: index, in: geo.size)
                                }
                            }
                            .transition(.scale(scale: 0.6).combined(with: .opacity))
                            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: bubble.position)
                            .animation(.spring(response: 0.3, dampingFraction: 0.85), value: lift)
                    }
                }
                // Keyboard-independent coordinate space for the cards: without
                // this `geo.size.height` shrinks when the keyboard appears, so
                // both `defaultSpawn` and the `snapped(_:in:)` clamp fed from
                // `containerSize` would compute against the wrong height — and
                // an absolutely-positioned card would not move anyway. The
                // cards rise instead via the measured `lift` above.
                .ignoresSafeArea(.keyboard)

                // The composer bar, in contrast, *does* take the keyboard safe
                // area, which is what parks it directly on top of the keyboard.
                if let composing = presenter.composingBubble {
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        FloatingChatComposerBar(bubble: composing, presenter: presenter)
                            // Identity per conversation: the bar's `init` is what
                            // binds its `@AppStorage` quick-emoji key, so SwiftUI
                            // must build a fresh one when composing moves to a
                            // different bubble rather than reusing this instance
                            // (which would keep the previous conversation's key,
                            // draft focus and picker state).
                            .id(composing.id)
                    }
                    .transition(.move(edge: .bottom))
                }
            }
            // Hidden, not removed, behind a full chat: positions and drafts survive.
            .opacity(presenter.isHiddenByFullChat ? 0 : 1)
            .allowsHitTesting(!presenter.bubbles.isEmpty && !presenter.isHiddenByFullChat)
            .animation(.easeInOut(duration: 0.2), value: presenter.isHiddenByFullChat)
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: presenter.bubbles.map(\.id))
            .animation(.spring(response: 0.3, dampingFraction: 0.85), value: presenter.composingBubble?.id)
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

    /// How far to raise a composing bubble so its bottom edge clears the
    /// docked composer bar, whose top edge is `composerTopY` (global coords —
    /// the bar reports it itself, so this needs no keyboard-height guess).
    ///
    /// Clamped so the lift can never push the card's top above `minTop`: on a
    /// short screen the keyboard plus the bar can demand more room than exists,
    /// and a card shoved off the top edge is the bug this whole change fixes.
    static func composeLift(cardCenterY: CGFloat, composerTopY: CGFloat) -> CGFloat {
        let gap: CGFloat = 10
        let needed = cardCenterY + bubbleHeight / 2 + gap - composerTopY
        guard needed > 0 else { return 0 }
        let minTop: CGFloat = 50   // clear the status bar
        let available = max(0, cardCenterY - bubbleHeight / 2 - minTop)
        return min(needed, available)
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

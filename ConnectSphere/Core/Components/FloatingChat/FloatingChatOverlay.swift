import SwiftUI

// MARK: - Overlay modifier
extension View {
    /// Attaches the floating chat window from `presenter`. Put this on a
    /// screen-level view (see `MainTabView`), the same way
    /// `.undoToastOverlay(_:)` is.
    func floatingChatOverlay(_ presenter: FloatingChatPresenter) -> some View {
        overlay { FloatingChatLayer(presenter: presenter) }
    }
}

// MARK: - Chat layer
/// The window, its stash tab and the docked reply bar, over the whole app.
private struct FloatingChatLayer: View {
    let presenter: FloatingChatPresenter

    /// The "+" picker for adding another chat to the window.
    @State private var showsAddSheet = false

    /// The size the user last pinched to; the larger one by default.
    @AppStorage("floatingChatSize", store: AppDefaults.store) private var sizeRaw = FloatingChatSize.regular.rawValue
    private var chatSize: FloatingChatSize { FloatingChatSize(rawValue: sizeRaw) ?? .regular }

    var body: some View {
        ZStack {
            GeometryReader { geo in
                // Tap-outside-to-dismiss-keyboard catcher, only present (and
                // only hit-testable) while a chat is composing; sits behind the
                // window so tapping it is unaffected, and behind the composer bar
                // (a later sibling of this layer) so tapping the field doesn't
                // dismiss it.
                if presenter.composingBubble != nil {
                    Color.clear
                        .contentShape(Rectangle())
                        .frame(width: geo.size.width, height: geo.size.height)
                        .onTapGesture { presenter.dismissAllComposing() }
                }
                if !presenter.bubbles.isEmpty {
                    window(in: geo.size)
                }
            }
            // Keyboard-independent coordinate space for the window: without
            // this `geo.size.height` shrinks when the keyboard appears, so both
            // `defaultSpawn` and the `snapped` clamp would compute against the
            // wrong height, and an absolutely-positioned window would not move
            // anyway. It rises instead via the measured `lift`.
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
                        // different chat rather than reusing this instance.
                        .id(composing.id)
                }
                .transition(.move(edge: .bottom))
            }
        }
        // Hidden, not removed, behind a full chat: position, chats and drafts survive.
        .opacity(presenter.isHiddenByFullChat ? 0 : 1)
        .allowsHitTesting(!presenter.bubbles.isEmpty && !presenter.isHiddenByFullChat)
        .animation(.easeInOut(duration: 0.2), value: presenter.isHiddenByFullChat)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: presenter.bubbles.isEmpty)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: presenter.composingBubble?.id)
        .sheet(isPresented: $showsAddSheet) {
            FloatingChatAddSheet(presenter: presenter)
        }
    }

    // MARK: - Chat window
    @ViewBuilder
    private func window(in container: CGSize) -> some View {
        let size = chatSize.size
        let center = presenter.windowPosition ?? FloatingChatLayout.defaultSpawn(size: size, in: container)
        let lift: CGFloat = {
            guard presenter.composingBubble != nil, let top = presenter.composerTopY else { return 0 }
            return FloatingChatLayout.composeLift(cardCenterY: center.y, cardHeight: size.height, composerTopY: top)
        }()
        // Stashed: slid fully past its edge, at the same height.
        let shown: CGPoint = {
            switch presenter.stashEdge {
            case .leading?: return CGPoint(x: -size.width / 2, y: center.y)
            case .trailing?: return CGPoint(x: container.width + size.width / 2, y: center.y)
            case nil: return center
            }
        }()

        FloatingChatWindowView(
            presenter: presenter, size: size,
            onDragEnded: { translation, predicted in
                endDrag(from: center, translation: translation, predicted: predicted, size: size, in: container)
            },
            onPinch: { magnification in pinch(magnification, center: center, in: container) },
            onAdd: {
                // The reply bar's keyboard and the sheet would fight.
                presenter.dismissAllComposing()
                showsAddSheet = true
            }
        )
        .position(shown)
        .offset(y: -lift)
        .onAppear {
            if presenter.windowPosition == nil { presenter.windowPosition = center }
        }
        .transition(.scale(scale: 0.6).combined(with: .opacity))
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: shown)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: lift)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: size)

        if let edge = presenter.stashEdge {
            FloatingChatStashTab(presenter: presenter, edge: edge)
                .position(x: edge == .leading ? 14 : container.width - 14, y: center.y)
                .transition(.opacity)
        }
    }

    // MARK: - Drag & pinch gestures
    /// A label drag ended: past a side edge (or flung hard at it) the window
    /// stashes there, like Apple's picture-in-picture; otherwise it snaps to
    /// the nearer side.
    private func endDrag(from center: CGPoint, translation: CGSize, predicted: CGSize,
                         size: CGSize, in container: CGSize) {
        let moved = CGPoint(x: center.x + translation.width, y: center.y + translation.height)
        let flung = CGPoint(x: center.x + predicted.width, y: center.y + translation.height)
        let edge = FloatingChatLayout.stashEdge(for: moved, size: size, in: container, beyond: 0.3)
            ?? FloatingChatLayout.stashEdge(for: flung, size: size, in: container, beyond: 0.5)
        presenter.windowPosition = FloatingChatLayout.snapped(moved, size: size, in: container)
        if let edge {
            presenter.stash(to: edge)
        }
    }

    /// Pinch out for the larger size, in for the smaller; the window stays on
    /// screen at its new size.
    private func pinch(_ magnification: CGFloat, center: CGPoint, in container: CGSize) {
        let next: FloatingChatSize
        if magnification > 1.08 { next = .regular } else if magnification < 0.92 { next = .compact } else { return }
        guard next != chatSize else { return }
        sizeRaw = next.rawValue
        presenter.windowPosition = FloatingChatLayout.snapped(center, size: next.size, in: container)
    }
}

// MARK: - Layout math
/// Sizing/placement maths for the floating window. Kept in one place so the
/// spawn, snap, stash and keyboard-lift rules stay consistent as sizes change.
enum FloatingChatLayout {
    static func defaultSpawn(size: CGSize, in container: CGSize) -> CGPoint {
        let margin: CGFloat = size.width / 2 + 12
        let bottomGutter: CGFloat = size.height / 2 + 150   // clears the tab bar
        return CGPoint(x: container.width - margin, y: container.height - bottomGutter)
    }

    /// How far to raise the composing window so its bottom edge clears the
    /// docked composer bar, whose top edge is `composerTopY` (global coords,
    /// the bar reports it itself, so this needs no keyboard-height guess).
    ///
    /// Clamped so the lift can never push the window's top above `minTop`: on
    /// a short screen the keyboard plus the bar can demand more room than
    /// exists, and a window shoved off the top edge is worse than an overlap.
    static func composeLift(cardCenterY: CGFloat, cardHeight: CGFloat, composerTopY: CGFloat) -> CGFloat {
        let gap: CGFloat = 10
        let needed = cardCenterY + cardHeight / 2 + gap - composerTopY
        guard needed > 0 else { return 0 }
        let minTop: CGFloat = 50   // clear the status bar
        let available = max(0, cardCenterY - cardHeight / 2 - minTop)
        return min(needed, available)
    }

    /// Snaps `point` to whichever horizontal edge it's closer to, clamping
    /// vertically so the window always stays fully on-screen.
    static func snapped(_ point: CGPoint, size: CGSize, in container: CGSize) -> CGPoint {
        guard container.width > 0, container.height > 0 else { return point }
        let halfWidth = size.width / 2
        let halfHeight = size.height / 2
        let edgeMargin: CGFloat = 10
        let minX = halfWidth + edgeMargin
        let maxX = max(minX, container.width - halfWidth - edgeMargin)
        let minY = halfHeight + 60   // clear the status bar / nav area
        let maxY = max(minY, container.height - halfHeight - 130)   // clear the tab bar
        let snappedX = point.x < container.width / 2 ? minX : maxX
        let clampedY = min(max(point.y, minY), maxY)
        return CGPoint(x: snappedX, y: clampedY)
    }

    /// The edge a window centred at `point` should stash into: when more than
    /// `beyond` of its width is past that side of the screen.
    static func stashEdge(for point: CGPoint, size: CGSize, in container: CGSize,
                          beyond fraction: CGFloat) -> FloatingChatStashEdge? {
        let overflow = size.width * fraction
        if point.x - size.width / 2 < -overflow { return .leading }
        if point.x + size.width / 2 > container.width + overflow { return .trailing }
        return nil
    }
}

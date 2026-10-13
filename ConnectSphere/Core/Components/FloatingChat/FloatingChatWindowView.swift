import SwiftUI

/// The floating window's two sizes, switched by pinching it.
enum FloatingChatSize: String {
    case compact, regular

    var size: CGSize {
        switch self {
        case .compact: return CGSize(width: 160, height: 285)
        case .regular: return CGSize(width: 200, height: 356)
        }
    }
}

/// The floating chat window: up to four chats, swiped left and right. The
/// label on top names the chat on screen, says where it is in the stack
/// ("2/4") and counts unread messages in the chats to either side — those
/// counts jump there. Dragging the label moves the window (the body's
/// horizontal swipes switch chats); flinging it off a side edge stashes it.
/// Single-tap a chat to mark it seen and reply; double-tap opens the full
/// chat; pinch switches between the two sizes.
struct FloatingChatWindowView: View {
    @Environment(\.colorScheme) private var colorScheme

    let presenter: FloatingChatPresenter
    let size: CGSize
    /// Where the window ended up after a label drag: moved (snapped) or stashed.
    let onDragEnded: (_ translation: CGSize, _ predicted: CGSize) -> Void
    let onPinch: (_ magnification: CGFloat) -> Void
    /// The label's "+": pick another chat to add.
    let onAdd: () -> Void

    @GestureState private var dragOffset: CGSize = .zero
    @State private var pagerID: String?

    var body: some View {
        VStack(spacing: 0) {
            FloatingChatLabel(presenter: presenter, onAdd: onAdd)
                .gesture(
                    DragGesture(minimumDistance: 3, coordinateSpace: .global)
                        .updating($dragOffset) { value, state, _ in state = value.translation }
                        .onEnded { onDragEnded($0.translation, $0.predictedEndTranslation) }
                )
            Divider()
            pager
        }
        .frame(width: size.width, height: size.height)
        .background(AppColors.surface(colorScheme))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.22), radius: 12, y: 5)
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .stroke(AppColors.borderDefault(colorScheme), lineWidth: 1))
        .offset(dragOffset)
        .simultaneousGesture(MagnifyGesture().onEnded { onPinch($0.magnification) })
        .onAppear { pagerID = presenter.active?.id }
        // The window shows another chat (an edge count, a new chat, a close).
        .onChange(of: presenter.active?.id) { _, id in
            guard id != pagerID else { return }
            withAnimation(.snappy) { pagerID = id }
        }
        // The user swiped to another chat.
        .onChange(of: pagerID) { _, id in
            guard let id, let bubble = presenter.bubbles.first(where: { $0.id == id }) else { return }
            presenter.activate(bubble)
        }
    }

    private var pager: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(presenter.bubbles) { bubble in
                    FloatingChatPage(bubble: bubble, presenter: presenter, width: size.width)
                        .containerRelativeFrame(.horizontal)
                        .id(bubble.id)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $pagerID)
        .scrollIndicators(.hidden)
        .scrollDisabled(presenter.bubbles.count < 2)
    }
}

/// The window's top bar and drag handle: unread to the left, the chat on
/// screen with its place in the stack, unread to the right, add, and close.
private struct FloatingChatLabel: View {
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appBundle) private var bundle

    let presenter: FloatingChatPresenter
    let onAdd: () -> Void

    var body: some View {
        VStack(spacing: 3) {
            // A grabber, so the label reads as the thing to drag.
            Capsule()
                .fill(AppColors.textTertiary(colorScheme).opacity(0.5))
                .frame(width: 26, height: 3)
            HStack(spacing: 4) {
                if presenter.unreadBefore > 0 {
                    edgeCount(presenter.unreadBefore, leading: true)
                }
                if let active = presenter.active {
                    Avatar(name: active.peer.name, colorHex: active.peer.avatarColor,
                           imageURL: active.peer.avatarUrl, size: .xs)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(active.peer.name)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(AppColors.textPrimary(colorScheme))
                            .lineLimit(1)
                        if presenter.bubbles.count > 1, let index = presenter.activeIndex {
                            Text(String(format: bundle.loc("%lld/%lld"), index + 1, presenter.bubbles.count))
                                .font(.system(size: 10, weight: .medium).monospacedDigit())
                                .foregroundColor(AppColors.textSecondary(colorScheme))
                        }
                    }
                }
                Spacer(minLength: 0)
                if presenter.unreadAfter > 0 {
                    edgeCount(presenter.unreadAfter, leading: false)
                }
                Button(action: onAdd) {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(themeManager.theme.primary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(bundle.loc("Add a chat")))
                if let active = presenter.active {
                    Button { withAnimation(.snappy) { presenter.close(active) } } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(AppColors.textTertiary(colorScheme))
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(bundle.loc("Close chat")))
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 4)
        .padding(.bottom, 6)
        .contentShape(Rectangle())
    }

    /// "‹ 3" / "5 ›": unread in the chats that way; tap to go one chat there.
    private func edgeCount(_ count: Int, leading: Bool) -> some View {
        Button {
            withAnimation(.snappy) { presenter.activateNeighbour(leading ? -1 : 1) }
        } label: {
            HStack(spacing: 1) {
                if leading { Image(systemName: "chevron.left") }
                Text(count > 99 ? "99+" : "\(count)")
                if !leading { Image(systemName: "chevron.right") }
            }
            .font(.system(size: 10, weight: .bold))
            .foregroundColor(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(themeManager.theme.primary, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(leading ? bundle.loc("Previous chat") : bundle.loc("Next chat")))
        .accessibilityValue(Text(String(format: bundle.loc("%lld unread"), count)))
    }
}

/// One chat's messages in the window, newest at the bottom.
private struct FloatingChatPage: View {
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appBundle) private var bundle

    let bubble: FloatingBubbleState
    let presenter: FloatingChatPresenter
    let width: CGFloat

    private static let historyLimit = 30
    private var contentWidth: CGFloat { width - 16 }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 6) {
                    if bubble.viewModel.messages.isEmpty {
                        Text("No messages yet", bundle: bundle)
                            .font(.system(size: 11))
                            .foregroundColor(AppColors.textTertiary(colorScheme))
                            .padding(.top, 20)
                    } else {
                        ForEach(bubble.viewModel.messages.suffix(Self.historyLimit)) { message in
                            FloatingChatMessageRow(message: message, bubble: bubble,
                                                   presenter: presenter, width: contentWidth)
                                .id(message.id)
                        }
                    }
                }
                .padding(8)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: bubble.viewModel.messages.last?.id) { _, id in
                guard let id else { return }
                withAnimation { proxy.scrollTo(id, anchor: .bottom) }
            }
        }
        .overlay(alignment: .bottom) {
            // New since the last tap — tapping the chat marks them seen.
            if bubble.unreadCount > 0 {
                Text(String(format: bundle.loc("%lld new"), bubble.unreadCount))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(themeManager.theme.primary, in: Capsule())
                    .padding(.bottom, 8)
                    .allowsHitTesting(false)
            }
        }
        .contentShape(Rectangle())
        // Plain (not simultaneous) taps, so a photo's or video's own tap wins.
        .onTapGesture(count: 2) { presenter.restore(bubble) }
        .onTapGesture {
            presenter.markSeen(bubble)
            presenter.toggleComposing(bubble)
        }
    }
}

/// What's left of a stashed window: a small tab on the edge, with a dot when
/// a chat has unread messages. Tap it, or pull it inward, to bring the
/// window back.
struct FloatingChatStashTab: View {
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.appBundle) private var bundle

    let presenter: FloatingChatPresenter
    let edge: FloatingChatStashEdge

    var body: some View {
        Image(systemName: edge == .leading ? "chevron.compact.right" : "chevron.compact.left")
            .font(.system(size: 22, weight: .semibold))
            .foregroundStyle(.primary)
            .frame(width: 28, height: 64)
            .modifier(StashTabGlass(edge: edge))
            .overlay(alignment: edge == .leading ? .topTrailing : .topLeading) {
                if presenter.totalUnread > 0 {
                    Circle().fill(themeManager.theme.primary)
                        .frame(width: 9, height: 9)
                        .offset(x: edge == .leading ? 2 : -2, y: 4)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { presenter.unstash() }
            .gesture(DragGesture(minimumDistance: 6).onEnded { value in
                let inward = edge == .leading ? value.translation.width : -value.translation.width
                if inward > 16 { presenter.unstash() }
            })
            .accessibilityElement()
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(Text(bundle.loc("Show chat")))
    }
}

/// Liquid Glass on iOS 26+, a material before — rounded on the screen side
/// only, so the tab looks tucked under the edge.
private struct StashTabGlass: ViewModifier {
    let edge: FloatingChatStashEdge

    private var shape: UnevenRoundedRectangle {
        edge == .leading
            ? UnevenRoundedRectangle(bottomTrailingRadius: 14, topTrailingRadius: 14)
            : UnevenRoundedRectangle(topLeadingRadius: 14, bottomLeadingRadius: 14)
    }

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: shape)
        } else {
            content.background(.ultraThinMaterial, in: shape)
        }
    }
}

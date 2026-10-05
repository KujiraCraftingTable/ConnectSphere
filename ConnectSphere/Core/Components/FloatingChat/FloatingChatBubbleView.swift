import SwiftUI

/// A minimized "chat head" — a small, compact read-only preview of the last
/// few messages in `bubble`'s conversation. Deliberately does NOT reuse
/// `MessageBubble` (built for full chat width, with voice/image/video/
/// meeting-card rendering that has no sensible tiny form) — instead renders
/// each message as one truncated line via `Message.preview`, the same
/// type-appropriate summary `ConversationListView`'s rows already use.
///
/// Single-tap toggles `bubble.isComposing`, which raises the keyboard and
/// docks `FloatingChatComposerBar` above it — the input deliberately does not
/// live in this view (see that type's doc comment); double-tap restores to a
/// full `ChatView` via `FloatingChatPresenter.restore(_:)`; drag repositions
/// it, snapping to whichever screen edge it's released closer to.
struct FloatingChatBubbleView: View {
    @Environment(AppState.self) var appState
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.appBundle) var bundle

    let bubble: FloatingBubbleState
    let presenter: FloatingChatPresenter
    /// The overlay's full size — needed to clamp/snap drag positions.
    let containerSize: CGSize

    /// Live finger-follow offset during a drag; committed into
    /// `bubble.position` (snapped) on release.
    @GestureState private var dragOffset: CGSize = .zero

    private var width: CGFloat { FloatingChatLayout.bubbleWidth }
    private var height: CGFloat { FloatingChatLayout.bubbleHeight }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            messagePreview
        }
        .frame(width: width, height: height)
        .background(AppColors.surface(colorScheme))
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .shadow(color: .black.opacity(0.22), radius: 10, y: 4)
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(AppColors.borderDefault(colorScheme), lineWidth: 1))
        .offset(dragOffset)
        .gesture(dragGesture)
        .simultaneousGesture(
            TapGesture(count: 2).onEnded { presenter.restore(bubble) }
                .exclusively(before: TapGesture(count: 1).onEnded { presenter.toggleComposing(bubble) })
        )
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 4)
            .updating($dragOffset) { value, state, _ in
                state = value.translation
            }
            .onEnded { value in
                let current = bubble.position ?? FloatingChatLayout.defaultSpawn(index: 0, in: containerSize)
                let moved = CGPoint(x: current.x + value.translation.width,
                                     y: current.y + value.translation.height)
                bubble.position = FloatingChatLayout.snapped(moved, in: containerSize)
                presenter.bringToFront(bubble)
            }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Avatar(name: bubble.peer.name, colorHex: bubble.peer.avatarColor,
                   imageURL: bubble.peer.avatarUrl, size: .xs)
            Text(bubble.peer.name)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(AppColors.textPrimary(colorScheme))
                .lineLimit(1)
            Spacer(minLength: 0)
            // Closes this bubble outright (conversation stops being live
            // anywhere) — separate from double-tap, which restores to full
            // ChatView instead. A plain Button here doesn't fight the drag/
            // tap gestures on the bubble body since it's its own hit target.
            Button {
                presenter.close(bubble)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(AppColors.textTertiary(colorScheme))
                    .padding(4)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private var messagePreview: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                if bubble.viewModel.messages.isEmpty {
                    Text("No messages yet", bundle: bundle)
                        .font(.system(size: 10))
                        .foregroundColor(AppColors.textTertiary(colorScheme))
                } else {
                    ForEach(Array(bubble.viewModel.messages.suffix(8))) { message in
                        previewRow(for: message)
                    }
                }
            }
            .padding(6)
        }
    }

    @ViewBuilder
    private func previewRow(for message: Message) -> some View {
        let isOwn = message.isOwn(userId: appState.currentUser?.id ?? bubble.currentUserId)
        let bubbleColor: Color = isOwn ? themeManager.theme.primary.opacity(0.85) : AppColors.elevated(colorScheme)
        let textColor: Color = isOwn ? .white : AppColors.textPrimary(colorScheme)
        Text(previewText(for: message))
            .font(.system(size: 10))
            .lineLimit(2)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(bubbleColor)
            .foregroundColor(textColor)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .frame(maxWidth: .infinity, alignment: isOwn ? .trailing : .leading)
    }

    /// Type-appropriate one-line summary — same convention as
    /// `PinnedMessage.preview`/`Conversation.previewText(currentUserId:)`,
    /// just scoped to a live `Message` instance instead of those two models.
    private func previewText(for message: Message) -> String {
        if message.isDeleted { return bundle.loc("Message unsent") }
        switch message.messageType {
        case .text, .unknown: return message.content ?? ""
        case .image:   return "📷 " + bundle.loc("Photo")
        case .video:   return "📹 " + bundle.loc("Video")
        case .meeting: return "📅 " + bundle.loc("Meeting")
        case .voice:   return "🎤 " + bundle.loc("Voice message")
        }
    }
}

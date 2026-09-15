import SwiftUI

/// A minimized "chat head" — a small, compact read-only preview of the last
/// few messages in `bubble`'s conversation. Deliberately does NOT reuse
/// `MessageBubble` (built for full chat width, with voice/image/video/
/// meeting-card rendering that has no sensible tiny form) — instead renders
/// each message as one truncated line via `Message.preview`, the same
/// type-appropriate summary `ConversationListView`'s rows already use.
///
/// Single-tap toggles `bubble.isComposing` (Phase 4 wires the actual compose
/// UI); double-tap restores to a full `ChatView` via
/// `FloatingChatPresenter.restore(_:)`. Static position for now — Phase 2
/// adds drag + edge-snap.
struct FloatingChatBubbleView: View {
    @Environment(AppState.self) var appState
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.appBundle) var bundle

    let bubble: FloatingBubbleState
    let presenter: FloatingChatPresenter

    private let width: CGFloat = 132
    private var height: CGFloat { width * 16 / 9 }

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
        .gesture(
            TapGesture(count: 2).onEnded { presenter.restore(bubble) }
                .exclusively(before: TapGesture(count: 1).onEnded { bubble.isComposing.toggle() })
        )
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

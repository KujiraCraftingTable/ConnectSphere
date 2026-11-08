import SwiftUI

struct MessageBubble: View {
    let message: Message
    let isOwn: Bool
    let palette: ThemePalette
    /// Needed to derive "my RSVP" from a meeting proposal's status→user-ids map
    /// (and whether this viewer whaled the message).
    var currentUserId: String = ""
    /// Every other participant in this conversation (excludes the current
    /// user), a 1:1 chat has exactly one id here, a group has N. Drives
    /// `statusIcon`'s delivered/read rendering; threaded in the same way
    /// `currentUserId` is (parent computes it once from `ChatViewModel`).
    var otherParticipantIds: [String] = []
    /// The conversation's canonical group/1:1 flag (`ChatViewModel.isGroup`,
    /// mirrors the server's `conversations.is_group`), NOT derived from
    /// `otherParticipantIds.count`, since a group can have as few as 1 other
    /// member (nothing enforces a minimum), which would make that heuristic
    /// disagree with the server. Drives meeting-proposal RSVP-vs-reminder
    /// gating, where the mismatch previously meant a 2-person group's meeting
    /// could never be RSVP'd to (and its reminder could never fire) since the
    /// UI rendered the 1:1 reminder-only row while the server still expected
    /// RSVPs. The read-receipts glyph below still keys off participant count
    /// on purpose, that's cosmetic (which glyph), not a lost feature.
    var isGroup: Bool = false
    /// Hobby mode = rounder bubble; Work mode = crisper bubble. Threaded in from ChatView
    /// (`appState.currentMode == .hobby`), same convention as `palette`.
    var isPlayful: Bool = false
    /// Whether this bubble shows "Seen"/"Unseen" under it. `ChatView` turns it
    /// on only for my latest message; bubbles carry no time of their own (the
    /// centered separators do).
    var showsMeta: Bool = true
    /// True while this chat is a message request the person hasn't accepted:
    /// the other side's photos and videos stay blurred until tapped.
    var coversStrangerMedia: Bool = false
    /// Tapping the image/video in the bubble, the parent opens the fullscreen viewer
    var onMediaTap: ((Message) -> Void)? = nil
    /// Tapping the quoted preview. The parent jumps to the original message (jump-to-message)
    var onReplyPreviewTap: ((String) -> Void)? = nil
    /// RSVP tapped on a meeting proposal card
    var onMeetingRespond: ((Message, MeetingRsvpStatus) -> Void)? = nil
    /// "Reschedule" chosen from the proposer's menu. Parent opens the composer pre-filled
    var onMeetingEdit: ((Message) -> Void)? = nil
    /// "Cancel meeting" confirmed from the proposer's menu
    var onMeetingCancel: ((Message) -> Void)? = nil
    /// An option tapped on a group poll (the option's id)
    var onPollVote: ((Message, String) -> Void)? = nil
    /// A shared post (`.post`) as this viewer sees it, loaded on appear.
    var sharedPost: ChatViewModel.SharedPostState? = nil
    var onSharedPostAppear: (() -> Void)? = nil
    var onOpenSharedPost: ((Post) -> Void)? = nil
    /// Double-tap: whale the message, or take the whale back.
    var onDoubleTap: (() -> Void)? = nil
    /// The long-press menu. Attached to the bubble, not the full-width row, so
    /// the menu opens right under the message instead of at the row's edge.
    var menuItems: AnyView? = nil
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.appBundle) var bundle
    @State private var showCancelConfirm = false
    @State private var revealedStrangerMedia = false
    /// "Edited" tapped: the text the edit replaced shows above the bubble.
    @State private var showsPreviousText = false

    private var bubbleShape: BubbleShape { BubbleShape(isOwn: isOwn, isPlayful: isPlayful) }

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            if isOwn { Spacer(minLength: 60) }

            VStack(alignment: isOwn ? .trailing : .leading, spacing: 3) {
                if let replyToId = message.replyToMessageId, let replied = message.repliedMessage {
                    replyPreview(replied, replyToId: replyToId)
                }
                if message.isForwarded && !message.isDeleted {
                    forwardedLabel
                }
                if let editedAt = message.editedAt, !message.isDeleted {
                    editedLabel(editedAt)
                    if showsPreviousText, let previous = message.previousContent {
                        previousTextBubble(previous)
                    }
                }
                bubbleContent
                    // Simultaneous, so single taps on photos, links and cards stay instant.
                    .simultaneousGesture(TapGesture(count: 2).onEnded {
                        if !message.isDeleted { onDoubleTap?() }
                    })
                    // Only the bubble lifts on long press, in its own shape.
                    .contentShape(.contextMenuPreview, bubbleShape)
                    .contextMenu { if let menuItems { menuItems } }
                    .overlay(alignment: isOwn ? .bottomLeading : .bottomTrailing) {
                        if message.whaleCount > 0 { whaleBadge }
                    }
                    // The whale hangs below the bubble; make room so it never covers
                    // the time or the next message.
                    .padding(.bottom, message.whaleCount > 0 ? 14 : 0)
                    .animation(.spring(response: 0.3, dampingFraction: 0.6), value: message.whaleCount)
                if showsMeta {
                    metaRow
                }
            }

            if !isOwn { Spacer(minLength: 60) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 2)
        .alert(
            Text("Cancel meeting proposal?", bundle: bundle),
            isPresented: $showCancelConfirm
        ) {
            Button(role: .destructive) {
                onMeetingCancel?(message)
            } label: {
                Text("Cancel meeting", bundle: bundle)
            }
            Button(role: .cancel) {
            } label: {
                Text("Keep it", bundle: bundle)
            }
        }
    }

    // MARK: - Quoted reply preview

    /// Compact quoted block above the bubble content. Tap jumps to the original message.
    ///
    /// It sits on the chat background, not inside the colored bubble, so it
    /// is a fixed light-grey chip with dark text in both light and dark mode.
    /// Colors that assumed the blue bubble behind it (white text on a 15%
    /// white wash) made it all but invisible on a light background.
    private func replyPreview(_ replied: RepliedMessage, replyToId: String) -> some View {
        Button {
            onReplyPreviewTap?(replyToId)
        } label: {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(palette.primary)
                    .frame(width: 3)

                VStack(alignment: .leading, spacing: 2) {
                    Text(replied.senderName)
                        .scaledFont(14, .semibold)
                        .foregroundColor(Self.replyChipName)
                        .lineLimit(1)
                    Text(replied.isDeleted ? bundle.loc("Message unsent") : (replied.content ?? ""))
                        .scaledFont(15)
                        .italic(replied.isDeleted)
                        .foregroundColor(Self.replyChipText)
                        .lineLimit(2)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: 260, alignment: .leading)
            .background(Self.replyChipBackground, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    // Deliberately not theme-adaptive: the chip stays light grey with dark
    // text in both modes, so the quote stands out on any chat background.
    private static let replyChipBackground = Color(white: 0.91)
    private static let replyChipName = Color(white: 0.15)
    private static let replyChipText = Color(white: 0.32)

    // MARK: - Whale and forwarded

    /// The whale on the bubble's corner once someone whaled it, with a count in a
    /// group. Always the filled whale in the chat's colour, whoever whaled it:
    /// it only shows when the message has been whaled.
    private var whaleBadge: some View {
        HStack(spacing: 2) {
            LikeIcon(isLiked: true, color: palette.primary, size: 16)
            if message.whaleCount > 1 {
                Text("\(message.whaleCount)")
                    .scaledFont(10, .semibold)
                    .foregroundColor(AppColors.textSecondary(colorScheme))
            }
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .background(AppColors.elevated(colorScheme), in: Capsule())
        .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
        .offset(x: isOwn ? -8 : 8, y: 10)
        .transition(.scale.combined(with: .opacity))
        .accessibilityLabel(Text(message.isWhaled(by: currentUserId) ? "You whaled this" : "Whaled", bundle: bundle))
    }

    /// "Forwarded" and nothing else: who wrote it originally is never shown or stored.
    private var forwardedLabel: some View {
        Label {
            Text("Forwarded", bundle: bundle)
        } icon: {
            Image(systemName: "arrowshape.turn.up.right")
        }
        .scaledFont(12)
        .foregroundColor(AppColors.textSecondary(colorScheme))
        .labelStyle(.titleAndIcon)
    }

    /// "Edited · 20:55" with the time of the edit; tapping it shows the text
    /// the edit replaced, and "Hide edits" puts it away again.
    private func editedLabel(_ editedAt: Date) -> some View {
        let time = Calendar.current.isDateInToday(editedAt)
            ? editedAt.formatted(date: .omitted, time: .shortened)
            : editedAt.dayMonthTime
        return Button {
            withAnimation(.easeInOut(duration: 0.2)) { showsPreviousText.toggle() }
        } label: {
            HStack(spacing: 0) {
                Text(showsPreviousText ? "Hide edits" : "Edited", bundle: bundle)
                    .foregroundColor(palette.primary)
                Text(verbatim: " · " + time)
                    .foregroundColor(AppColors.textSecondary(colorScheme))
            }
            .scaledFont(12)
        }
        .buttonStyle(.plain)
        .disabled(message.previousContent == nil)
        .accessibilityHint(Text(showsPreviousText ? "Hides the earlier text" : "Shows the earlier text", bundle: bundle))
    }

    /// The text before the last edit: the same bubble, dimmed, so it reads as
    /// what the message used to say.
    private func previousTextBubble(_ text: String) -> some View {
        Text(text)
            .scaledFont(17)
            .foregroundColor(isOwn ? .white.opacity(0.85) : AppColors.textSecondary(colorScheme))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(bubbleBackground.opacity(0.45))
            .clipShape(bubbleShape)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    // MARK: - Bubble content

    @ViewBuilder
    private var bubbleContent: some View {
        if message.isDeleted {
            // Placeholder for a recalled message
            Text("Message unsent", bundle: bundle)
                .scaledFont(16)
                .italic()
                .foregroundColor(AppColors.textTertiary(colorScheme))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(AppColors.elevated(colorScheme))
                .clipShape(bubbleShape)
        } else {
            normalBubbleContent
                .sensitiveMediaCover(
                    coversStrangerMedia && !isOwn && !revealedStrangerMedia && [.image, .album, .video].contains(message.messageType),
                    onReveal: { revealedStrangerMedia = true })
        }
    }

    @ViewBuilder
    private var normalBubbleContent: some View {
        switch message.messageType {
        case .text, .unknown:
            if let text = message.content {
                Text(text)
                    .scaledFont(17)
                    .foregroundColor(isOwn ? .white : AppColors.textPrimary(colorScheme))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(bubbleBackground)
                    .clipShape(bubbleShape)
            }

        case .image:
            if let url = message.absoluteMediaURL() {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let img):
                        img.resizable()
                            .scaledToFill()
                            .frame(maxWidth: 220, maxHeight: 260)
                            .clipShape(bubbleShape)
                            .contentShape(bubbleShape)
                            .onTapGesture { onMediaTap?(message) }
                    case .failure:
                        imagePlaceholder(icon: "photo", label: bundle.loc("Photo"))
                    default:
                        ProgressView()
                            .frame(width: 180, height: 140)
                            .background(AppColors.elevated(colorScheme))
                            .clipShape(bubbleShape)
                    }
                }
            }

        case .album:
            VStack(alignment: isOwn ? .trailing : .leading, spacing: 4) {
                AlbumStackBubble(urls: message.albumURLs(), isOwn: isOwn) { onMediaTap?(message) }
                if let caption = message.content, !caption.isEmpty {
                    Text(caption)
                        .scaledFont(17)
                        .foregroundColor(isOwn ? .white : AppColors.textPrimary(colorScheme))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(bubbleBackground)
                        .clipShape(bubbleShape)
                }
            }

        case .video:
            videoBubble

        case .voice:
            voiceBubble

        case .meeting:
            if let proposal = message.meetingProposal {
                MeetingProposalCard(
                    proposal: proposal, isOwn: isOwn, isGroup: isGroup, currentUserId: currentUserId,
                    accent: palette.primary, isPlayful: isPlayful,
                    onRespond: { status in onMeetingRespond?(message, status) },
                    onReschedule: { onMeetingEdit?(message) },
                    onCancel: { showCancelConfirm = true }
                )
            }

        case .poll:
            if let poll = message.poll {
                ChatPollCard(question: message.content ?? "", poll: poll, currentUserId: currentUserId,
                             accent: palette.primary,
                             onVote: { optionId in onPollVote?(message, optionId) })
            }

        case .post:
            // The sender's note, then the post itself.
            VStack(alignment: isOwn ? .trailing : .leading, spacing: 4) {
                if let note = message.content, !note.isEmpty {
                    Text(note)
                        .scaledFont(17)
                        .foregroundColor(isOwn ? .white : AppColors.textPrimary(colorScheme))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(bubbleBackground)
                        .clipShape(bubbleShape)
                }
                ChatSharedPostCard(state: sharedPost, accent: palette.primary,
                                   onAppear: { onSharedPostAppear?() },
                                   onOpen: { onOpenSharedPost?($0) })
            }

        case .community:
            VStack(alignment: isOwn ? .trailing : .leading, spacing: 4) {
                if let note = message.content, !note.isEmpty {
                    Text(note)
                        .scaledFont(17)
                        .foregroundColor(isOwn ? .white : AppColors.textPrimary(colorScheme))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(bubbleBackground)
                        .clipShape(bubbleShape)
                }
                if let id = message.sharedCommunityId {
                    ChatCommunityCard(communityId: id)
                }
            }
        }
    }

    /// Video bubble: dark background + play button, tapping opens the fullscreen viewer
    /// (video doesn't play inline in the list).
    private var videoBubble: some View {
        ZStack {
            Rectangle().fill(Color.black.opacity(0.85))
            Image(systemName: "play.circle.fill")
                .scaledFont(42)
                .foregroundColor(.white.opacity(0.92))
        }
        .frame(width: 200, height: 140)
        .clipShape(bubbleShape)
        .contentShape(bubbleShape)
        .onTapGesture { onMediaTap?(message) }
    }

    // MARK: - Voice message bubble

    private var voiceBubble: some View {
        VoiceMessagePlayer(message: message, isOwn: isOwn, accent: palette.primary)
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)
            .frame(width: 230)
            .background(bubbleBackground)
            .clipShape(bubbleShape)
    }

    private func imagePlaceholder(icon: String, label: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .scaledFont(22)
                .foregroundColor(isOwn ? .white.opacity(0.8) : AppColors.textSecondary(colorScheme))
            Text(label)
                .scaledFont(14, .medium)
                .foregroundColor(isOwn ? .white : AppColors.textPrimary(colorScheme))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(bubbleBackground)
        .clipShape(bubbleShape)
    }

    private var bubbleBackground: some ShapeStyle {
        isOwn
            ? AnyShapeStyle(palette.primary)
            : AnyShapeStyle(AppColors.surface(colorScheme))
    }

    // MARK: - Timestamp + status

    @ViewBuilder
    private var metaRow: some View {
        if isOwn { statusIcon }
    }

    /// "Unseen" until the other person has read it, then nothing. Groups show
    /// "Read n/total" while only some have read it and nothing once all have.
    @ViewBuilder
    private var statusIcon: some View {
        let total = otherParticipantIds.count
        let readCount = message.readCount(among: otherParticipantIds)

        if total > 1, readCount > 0, readCount < total {
            Text(String(format: bundle.loc("Read %d/%d"), readCount, total))
                .scaledFont(12, .medium)
                .foregroundColor(AppColors.textTertiary(colorScheme))
        } else if total > 0, readCount < total {
            Text(bundle.loc("Unseen"))
                .scaledFont(12, .medium)
                .foregroundColor(AppColors.textTertiary(colorScheme))
        }
    }
}

// MARK: - Bubble Shape

private struct BubbleShape: Shape {
    let isOwn: Bool
    /// Hobby mode gets a rounder, softer bubble; Work mode a crisper one.
    /// Baseline (both modes before this) was r=18/tail=4.
    var isPlayful: Bool = false
    private var r: CGFloat { isPlayful ? 20 : 15 }
    private var tail: CGFloat { isPlayful ? 6 : 3 }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let (minX, maxX, minY, maxY) = (rect.minX, rect.maxX, rect.minY, rect.maxY)

        if isOwn {
            path.move(to: CGPoint(x: minX + r, y: minY))
            path.addLine(to: CGPoint(x: maxX - r, y: minY))
            path.addQuadCurve(to: CGPoint(x: maxX, y: minY + r), control: CGPoint(x: maxX, y: minY))
            // The tail corner mirrors the received bubble's: as tall as it is wide.
            path.addLine(to: CGPoint(x: maxX, y: maxY - tail))
            path.addQuadCurve(to: CGPoint(x: maxX - tail, y: maxY), control: CGPoint(x: maxX, y: maxY))
            path.addLine(to: CGPoint(x: minX + r, y: maxY))
            path.addQuadCurve(to: CGPoint(x: minX, y: maxY - r), control: CGPoint(x: minX, y: maxY))
            path.addLine(to: CGPoint(x: minX, y: minY + r))
            path.addQuadCurve(to: CGPoint(x: minX + r, y: minY), control: CGPoint(x: minX, y: minY))
        } else {
            path.move(to: CGPoint(x: minX + r, y: minY))
            path.addLine(to: CGPoint(x: maxX - r, y: minY))
            path.addQuadCurve(to: CGPoint(x: maxX, y: minY + r), control: CGPoint(x: maxX, y: minY))
            path.addLine(to: CGPoint(x: maxX, y: maxY - r))
            path.addQuadCurve(to: CGPoint(x: maxX - r, y: maxY), control: CGPoint(x: maxX, y: maxY))
            path.addLine(to: CGPoint(x: minX + tail, y: maxY))
            path.addQuadCurve(to: CGPoint(x: minX, y: maxY - tail), control: CGPoint(x: minX, y: maxY))
            path.addLine(to: CGPoint(x: minX, y: minY + r))
            path.addQuadCurve(to: CGPoint(x: minX + r, y: minY), control: CGPoint(x: minX, y: minY))
        }
        path.closeSubpath()
        return path
    }
}

// MARK: - Typing indicator dots

struct TypingIndicatorBubble: View {
    @Environment(\.colorScheme) var colorScheme
    @State private var phase: Int = 0

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(AppColors.textTertiary(colorScheme))
                    .frame(width: 7, height: 7)
                    .scaleEffect(phase == i ? 1.3 : 1.0)
                    .animation(.easeInOut(duration: 0.4).repeatForever(autoreverses: true).delay(Double(i) * 0.15), value: phase)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(AppColors.surface(colorScheme))
        .clipShape(BubbleShape(isOwn: false))
        .padding(.leading, 12)
        .onAppear { phase = 0 }
    }
}

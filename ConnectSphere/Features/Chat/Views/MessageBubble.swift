import SwiftUI

struct MessageBubble: View {
    let message: Message
    let isOwn: Bool
    let palette: ThemePalette
    /// Needed to derive "my RSVP" from a meeting proposal's status→user-ids map
    /// (same convention as `Message.myReaction(userId:)`).
    var currentUserId: String = ""
    /// Every other participant in this conversation (excludes the current
    /// user) — a 1:1 chat has exactly one id here, a group has N. Drives
    /// `statusIcon`'s delivered/read rendering; threaded in the same way
    /// `currentUserId` is (parent computes it once from `ChatViewModel`).
    var otherParticipantIds: [String] = []
    /// The conversation's canonical group/1:1 flag (`ChatViewModel.isGroup`,
    /// mirrors the server's `conversations.is_group`) — NOT derived from
    /// `otherParticipantIds.count`, since a group can have as few as 1 other
    /// member (nothing enforces a minimum), which would make that heuristic
    /// disagree with the server. Drives meeting-proposal RSVP-vs-reminder
    /// gating, where the mismatch previously meant a 2-person group's meeting
    /// could never be RSVP'd to (and its reminder could never fire) since the
    /// UI rendered the 1:1 reminder-only row while the server still expected
    /// RSVPs. The read-receipts glyph below still keys off participant count
    /// on purpose — that's cosmetic (which glyph), not a lost feature.
    var isGroup: Bool = false
    /// Hobby mode = rounder bubble + bigger reaction pills; Work mode = crisper
    /// bubble + today's tighter reaction-pill sizing. Threaded in from ChatView
    /// (`appState.currentMode == .hobby`), same convention as `palette`.
    var isPlayful: Bool = false
    /// Whether this bubble shows its time + read receipt. `ChatView` turns it
    /// off for all but the last message in a same-sender run
    /// (`ChatTimeline.endsRun`), so a burst of messages carries one time
    /// instead of a stamp on every line.
    var showsMeta: Bool = true
    /// Tapping the image/video in the bubble — the parent opens the fullscreen viewer
    var onMediaTap: ((Message) -> Void)? = nil
    /// Tapping the quoted preview — the parent jumps to the original message (jump-to-message)
    var onReplyPreviewTap: ((String) -> Void)? = nil
    /// RSVP tapped on a meeting proposal card
    var onMeetingRespond: ((Message, MeetingRsvpStatus) -> Void)? = nil
    /// "Reschedule" chosen from the proposer's menu — parent opens the composer pre-filled
    var onMeetingEdit: ((Message) -> Void)? = nil
    /// "Cancel meeting" confirmed from the proposer's menu
    var onMeetingCancel: ((Message) -> Void)? = nil
    /// An option tapped on a group poll (the option's id)
    var onPollVote: ((Message, String) -> Void)? = nil
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.appBundle) var bundle
    @State private var showCancelConfirm = false

    private var bubbleShape: BubbleShape { BubbleShape(isOwn: isOwn, isPlayful: isPlayful) }

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            if isOwn { Spacer(minLength: 60) }

            VStack(alignment: isOwn ? .trailing : .leading, spacing: 3) {
                if let replyToId = message.replyToMessageId, let replied = message.repliedMessage {
                    replyPreview(replied, replyToId: replyToId)
                }
                bubbleContent
                if !message.reactions.isEmpty {
                    reactionRow
                }
                if showsMeta {
                    metaRow
                }
            }

            if !isOwn { Spacer(minLength: 60) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 2)
        .confirmationDialog(
            Text("Cancel meeting proposal?", bundle: bundle),
            isPresented: $showCancelConfirm,
            titleVisibility: .visible
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

    /// Compact quoted block above the bubble content — tap jumps to the original message.
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
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Self.replyChipName)
                        .lineLimit(1)
                    Text(replied.isDeleted ? bundle.loc("Message unsent") : (replied.content ?? ""))
                        .font(.system(size: 13))
                        .italic(replied.isDeleted)
                        .foregroundColor(Self.replyChipText)
                        .lineLimit(2)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: 240, alignment: .leading)
            .background(Self.replyChipBackground, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    // Deliberately not theme-adaptive: the chip stays light grey with dark
    // text in both modes, so the quote stands out on any chat background.
    private static let replyChipBackground = Color(white: 0.91)
    private static let replyChipName = Color(white: 0.15)
    private static let replyChipText = Color(white: 0.32)

    // MARK: - Reaction pills

    /// Small pill row below the bubble summarising reactions (emoji + count).
    /// The current user's own reaction (if any) is highlighted in the palette
    /// color so it reads distinctly from everyone else's.
    private var reactionRow: some View {
        let mine = message.myReaction(userId: currentUserId)
        return HStack(spacing: 4) {
            ForEach(message.reactionSummary, id: \.emoji) { item in
                let isMine = item.emoji == mine
                HStack(spacing: 2) {
                    Text(item.emoji).font(.system(size: isPlayful ? 13 : 11))
                    if item.count > 1 {
                        Text("\(item.count)")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(isMine ? .white : AppColors.textSecondary(colorScheme))
                    }
                }
                .padding(.horizontal, isPlayful ? 7 : 6)
                .padding(.vertical, isPlayful ? 4 : 3)
                .background(isMine ? AnyShapeStyle(palette.primary) : AnyShapeStyle(AppColors.elevated(colorScheme)), in: Capsule())
            }
        }
    }

    // MARK: - Bubble content

    @ViewBuilder
    private var bubbleContent: some View {
        if message.isDeleted {
            // Placeholder for a recalled message
            Text("Message unsent", bundle: bundle)
                .font(.system(size: 14))
                .italic()
                .foregroundColor(AppColors.textTertiary(colorScheme))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(AppColors.elevated(colorScheme))
                .clipShape(bubbleShape)
        } else {
            normalBubbleContent
        }
    }

    @ViewBuilder
    private var normalBubbleContent: some View {
        switch message.messageType {
        case .text, .unknown:
            if let text = message.content {
                Text(text)
                    .font(.system(size: 15))
                    .foregroundColor(isOwn ? .white : AppColors.textPrimary(colorScheme))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
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
                        .font(.system(size: 15))
                        .foregroundColor(isOwn ? .white : AppColors.textPrimary(colorScheme))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
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
        }
    }

    /// Video bubble: dark background + play button, tapping opens the fullscreen viewer
    /// (video doesn't play inline in the list).
    private var videoBubble: some View {
        ZStack {
            Rectangle().fill(Color.black.opacity(0.85))
            Image(systemName: "play.circle.fill")
                .font(.system(size: 42))
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
                .font(.system(size: 22))
                .foregroundColor(isOwn ? .white.opacity(0.8) : AppColors.textSecondary(colorScheme))
            Text(label)
                .font(.system(size: 14, weight: .medium))
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

    private var metaRow: some View {
        HStack(spacing: 4) {
            Text(message.createdAt.formatted(.dateTime.hour().minute()))
                .font(.system(size: 11))
                .foregroundColor(AppColors.textTertiary(colorScheme))

            if isOwn {
                statusIcon
            }
        }
    }

    /// Derived from `deliveredTo`/`readBy` against `otherParticipantIds` rather
    /// than a single enum. For the 1:1 case (exactly one other participant)
    /// this reproduces the old `sent`/`delivered`/`read` visuals exactly —
    /// single checkmark / hollow double-check / filled colored double-check —
    /// since "the other person" is the entire `otherParticipantIds` set.
    /// Groups (N > 1) instead show a compact "Read n/total" label once at
    /// least one other member has read it, falling back to the same
    /// sent/delivered glyphs otherwise.
    @ViewBuilder
    private var statusIcon: some View {
        let total = otherParticipantIds.count
        let readCount = message.readCount(among: otherParticipantIds)
        let deliveredCount = message.deliveredCount(among: otherParticipantIds)

        if total > 1 {
            groupStatusView(readCount: readCount, total: total)
        } else if readCount > 0 {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 11))
                .foregroundColor(palette.primary)
        } else if deliveredCount > 0 {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 11))
                .foregroundColor(AppColors.textTertiary(colorScheme))
        } else {
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(AppColors.textTertiary(colorScheme))
        }
    }

    /// Group (N > 1 other participants) status: filled colored check once
    /// everyone has read it, a compact "Read n/total" label while some (but
    /// not all) have, otherwise the same sent/delivered glyph the 1:1 case
    /// uses — kept unobtrusive so it doesn't widen the bubble's meta row.
    @ViewBuilder
    private func groupStatusView(readCount: Int, total: Int) -> some View {
        if readCount >= total {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 11))
                .foregroundColor(palette.primary)
        } else if readCount > 0 {
            Text(String(format: bundle.loc("Read %d/%d"), readCount, total))
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(AppColors.textTertiary(colorScheme))
        } else if message.deliveredCount(among: otherParticipantIds) > 0 {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 11))
                .foregroundColor(AppColors.textTertiary(colorScheme))
        } else {
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .semibold))
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
            path.addLine(to: CGPoint(x: maxX, y: maxY - r - tail))
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

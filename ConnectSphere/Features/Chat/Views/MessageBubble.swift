import SwiftUI

struct MessageBubble: View {
    let message: Message
    let isOwn: Bool
    let palette: ThemePalette
    /// Needed to derive "my RSVP" from a meeting proposal's status→user-ids map
    /// (same convention as `Message.myReaction(userId:)`).
    var currentUserId: String = ""
    /// Bấm vào ảnh/video trong bubble — parent mở viewer fullscreen
    var onMediaTap: ((Message) -> Void)? = nil
    /// Bấm vào phần preview trích dẫn — parent nhảy tới tin nhắn gốc (jump-to-message)
    var onReplyPreviewTap: ((String) -> Void)? = nil
    /// RSVP tapped on a meeting proposal card
    var onMeetingRespond: ((Message, MeetingRsvpStatus) -> Void)? = nil
    /// "Reschedule" chosen from the proposer's menu — parent opens the composer pre-filled
    var onMeetingEdit: ((Message) -> Void)? = nil
    /// "Cancel meeting" confirmed from the proposer's menu
    var onMeetingCancel: ((Message) -> Void)? = nil
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.appBundle) var bundle
    @State private var showCancelConfirm = false

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
                metaRow
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
    private func replyPreview(_ replied: RepliedMessage, replyToId: String) -> some View {
        Button {
            onReplyPreviewTap?(replyToId)
        } label: {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(isOwn ? Color.white.opacity(0.6) : palette.primary)
                    .frame(width: 3)

                VStack(alignment: .leading, spacing: 1) {
                    Text(replied.senderName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(isOwn ? .white.opacity(0.85) : palette.primary)
                        .lineLimit(1)
                    Text(replied.isDeleted ? bundle.loc("Message unsent") : (replied.content ?? ""))
                        .font(.system(size: 12))
                        .italic(replied.isDeleted)
                        .foregroundColor(isOwn ? .white.opacity(0.75) : AppColors.textSecondary(colorScheme))
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: 220, alignment: .leading)
            .background(
                (isOwn ? Color.white.opacity(0.15) : AppColors.elevated(colorScheme)),
                in: RoundedRectangle(cornerRadius: 8)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Reaction pills

    /// Small pill row below the bubble summarising reactions (emoji + count).
    private var reactionRow: some View {
        HStack(spacing: 4) {
            ForEach(message.reactionSummary, id: \.emoji) { item in
                HStack(spacing: 2) {
                    Text(item.emoji).font(.system(size: 11))
                    if item.count > 1 {
                        Text("\(item.count)")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(AppColors.textSecondary(colorScheme))
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(AppColors.elevated(colorScheme), in: Capsule())
            }
        }
    }

    // MARK: - Bubble content

    @ViewBuilder
    private var bubbleContent: some View {
        if message.isDeleted {
            // Placeholder cho tin đã thu hồi
            Text("Message unsent", bundle: bundle)
                .font(.system(size: 14))
                .italic()
                .foregroundColor(AppColors.textTertiary(colorScheme))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(AppColors.elevated(colorScheme))
                .clipShape(BubbleShape(isOwn: isOwn))
        } else {
            normalBubbleContent
        }
    }

    @ViewBuilder
    private var normalBubbleContent: some View {
        switch message.messageType {
        case .text:
            if let text = message.content {
                Text(text)
                    .font(.system(size: 15))
                    .foregroundColor(isOwn ? .white : AppColors.textPrimary(colorScheme))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(bubbleBackground)
                    .clipShape(BubbleShape(isOwn: isOwn))
            }

        case .image:
            if let url = message.absoluteMediaURL() {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let img):
                        img.resizable()
                            .scaledToFill()
                            .frame(maxWidth: 220, maxHeight: 260)
                            .clipShape(BubbleShape(isOwn: isOwn))
                            .contentShape(BubbleShape(isOwn: isOwn))
                            .onTapGesture { onMediaTap?(message) }
                    case .failure:
                        imagePlaceholder(icon: "photo", label: bundle.loc("Photo"))
                    default:
                        ProgressView()
                            .frame(width: 180, height: 140)
                            .background(AppColors.elevated(colorScheme))
                            .clipShape(BubbleShape(isOwn: isOwn))
                    }
                }
            }

        case .video:
            videoBubble

        case .meeting:
            if let proposal = message.meetingProposal {
                meetingProposalCard(proposal)
            }
        }
    }

    // MARK: - Meeting proposal card

    /// Card shown for `.meeting` messages: calendar icon, title, formatted date,
    /// optional location, a 3-button RSVP strip (going count), and — for the
    /// proposer only — a menu to reschedule/cancel. Cancelled proposals render
    /// muted/struck-through with RSVP disabled.
    private func meetingProposalCard(_ proposal: MeetingProposal) -> some View {
        let cancelled = proposal.isCancelled
        let iconColor = cancelled ? AppColors.textTertiary(colorScheme) : palette.primary

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "calendar")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(iconColor)
                    .frame(width: 32, height: 32)
                    .background(iconColor.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 2) {
                    Text(proposal.title)
                        .font(.system(size: 15, weight: .semibold))
                        .strikethrough(cancelled)
                        .foregroundColor(cancelled ? AppColors.textTertiary(colorScheme) : AppColors.textPrimary(colorScheme))
                    Text(formattedMeetingDate(proposal.startsAt))
                        .font(.system(size: 13))
                        .foregroundColor(AppColors.textSecondary(colorScheme))
                }

                Spacer(minLength: 4)

                if isOwn && !cancelled {
                    Menu {
                        Button {
                            onMeetingEdit?(message)
                        } label: {
                            Label(bundle.loc("Reschedule"), systemImage: "pencil")
                        }
                        Button(role: .destructive) {
                            showCancelConfirm = true
                        } label: {
                            Label(bundle.loc("Cancel meeting"), systemImage: "xmark.circle")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(AppColors.textSecondary(colorScheme))
                            .padding(6)
                    }
                }
            }

            if let location = proposal.location, !location.isEmpty {
                Label(location, systemImage: "mappin.circle")
                    .font(.system(size: 13))
                    .foregroundColor(AppColors.textSecondary(colorScheme))
            }

            if cancelled {
                Text("Cancelled", bundle: bundle)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.red)
            } else {
                HStack(spacing: 8) {
                    ForEach([MeetingRsvpStatus.going, .maybe, .notGoing], id: \.self) { status in
                        meetingRsvpButton(status, proposal: proposal)
                    }
                    Spacer()
                    Text(String(format: bundle.loc("%d going"), proposal.count(for: .going)))
                        .font(.system(size: 12))
                        .foregroundColor(AppColors.textTertiary(colorScheme))
                }
            }
        }
        .padding(12)
        .frame(maxWidth: 260, alignment: .leading)
        .background(AppColors.elevated(colorScheme), in: RoundedRectangle(cornerRadius: 14))
        .opacity(cancelled ? 0.65 : 1)
    }

    private func meetingRsvpButton(_ status: MeetingRsvpStatus, proposal: MeetingProposal) -> some View {
        let isActive = proposal.myResponse(userId: currentUserId) == status
        return Button {
            onMeetingRespond?(message, status)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: status.icon)
                    .font(.system(size: 12))
                meetingRsvpLabel(status)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundColor(isActive ? .white : AppColors.textSecondary(colorScheme))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(isActive ? palette.primary : AppColors.base(colorScheme))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func meetingRsvpLabel(_ status: MeetingRsvpStatus) -> Text {
        switch status {
        case .going:    return Text("Going", bundle: bundle)
        case .maybe:    return Text("Maybe", bundle: bundle)
        case .notGoing: return Text("Can't go", bundle: bundle)
        }
    }

    /// Short formatted date: "Sat, Jun 7 · 7:00 PM" — same format as EventPostCard.
    private func formattedMeetingDate(_ date: Date) -> String {
        let df = DateFormatter()
        df.dateFormat = "EEE, MMM d"
        let tf = DateFormatter()
        tf.dateFormat = "h:mm a"
        return "\(df.string(from: date)) · \(tf.string(from: date))"
    }

    /// Bubble video: nền tối + nút play, bấm mở viewer fullscreen
    /// (video không phát inline trong list).
    private var videoBubble: some View {
        ZStack {
            Rectangle().fill(Color.black.opacity(0.85))
            Image(systemName: "play.circle.fill")
                .font(.system(size: 42))
                .foregroundColor(.white.opacity(0.92))
        }
        .frame(width: 200, height: 140)
        .clipShape(BubbleShape(isOwn: isOwn))
        .contentShape(BubbleShape(isOwn: isOwn))
        .onTapGesture { onMediaTap?(message) }
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
        .clipShape(BubbleShape(isOwn: isOwn))
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

    @ViewBuilder
    private var statusIcon: some View {
        switch message.status {
        case .sent:
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(AppColors.textTertiary(colorScheme))
        case .delivered:
            Image(systemName: "checkmark.circle")
                .font(.system(size: 11))
                .foregroundColor(AppColors.textTertiary(colorScheme))
        case .read:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 11))
                .foregroundColor(palette.primary)
        }
    }
}

// MARK: - Bubble Shape

private struct BubbleShape: Shape {
    let isOwn: Bool
    private let r: CGFloat = 18
    private let tail: CGFloat = 4

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

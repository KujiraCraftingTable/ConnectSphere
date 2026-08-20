import SwiftUI

struct MessageBubble: View {
    let message: Message
    let isOwn: Bool
    let palette: ThemePalette
    /// Bấm vào ảnh/video trong bubble — parent mở viewer fullscreen
    var onMediaTap: ((Message) -> Void)? = nil
    /// Bấm vào phần preview trích dẫn — parent nhảy tới tin nhắn gốc (jump-to-message)
    var onReplyPreviewTap: ((String) -> Void)? = nil
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.appBundle) var bundle

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
        }
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

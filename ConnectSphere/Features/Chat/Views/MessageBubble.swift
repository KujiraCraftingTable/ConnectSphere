import SwiftUI

struct MessageBubble: View {
    let message: Message
    let isOwn: Bool
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            if isOwn { Spacer(minLength: 60) }

            VStack(alignment: isOwn ? .trailing : .leading, spacing: 3) {
                bubbleContent
                metaRow
            }

            if !isOwn { Spacer(minLength: 60) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 2)
    }

    // MARK: - Bubble content

    @ViewBuilder
    private var bubbleContent: some View {
        if message.isDeleted {
            // Placeholder cho tin đã thu hồi
            Text("Tin nhắn đã được thu hồi")
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
                    case .failure:
                        imagePlaceholder(icon: "photo", label: "Ảnh")
                    default:
                        ProgressView()
                            .frame(width: 180, height: 140)
                            .background(AppColors.elevated(colorScheme))
                            .clipShape(BubbleShape(isOwn: isOwn))
                    }
                }
            }

        case .video:
            imagePlaceholder(icon: "play.circle.fill", label: "Video")
        }
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
            ? AnyShapeStyle(themeManager.theme.primary)
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
                .foregroundColor(themeManager.theme.primary)
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

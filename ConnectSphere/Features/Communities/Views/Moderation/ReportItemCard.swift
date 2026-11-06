import SwiftUI

/// Card displaying one report item in the moderation queue
struct ReportItemCard: View {
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.appBundle) var bundle
    let item: ModerationItem
    let isPending: Bool
    let coverColor: String
    let onRemove: () -> Void
    let onBan:    () -> Void
    let onDismiss: () -> Void

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header row
            HStack(spacing: 10) {
                typeIcon
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(bundle.loc(reasonLabel))
                            .scaledFont(14, .semibold)
                            .foregroundColor(AppColors.textPrimary(colorScheme))
                        statusBadge
                    }
                    Text(item.createdAt.timeAgoString)
                        .scaledFont(12)
                        .foregroundColor(AppColors.textTertiary(colorScheme))
                }
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
                } label: {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .scaledFont(13)
                        .foregroundColor(AppColors.textTertiary(colorScheme))
                }
                .accessibilityLabel(isExpanded ? Bundle.app.loc("Show less") : Bundle.app.loc("Show more"))
                .buttonStyle(.plain)
            }
            .padding(14)

            // Expandable content
            if isExpanded {
                Divider().padding(.horizontal, 14)
                targetPreview
                    .padding(14)
                if isPending {
                    actionButtons
                        .padding(.horizontal, 14)
                        .padding(.bottom, 14)
                }
            }
        }
        .surfaceBackground()
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.2 : 0.05), radius: 3, x: 0, y: 1)
    }

    // MARK: - Subviews

    private var typeIcon: some View {
        Image(systemName: item.targetType == "post" ? "doc.text" : "person.fill")
            .scaledFont(14)
            .foregroundColor(Color(hex: coverColor))
            .frame(width: 32, height: 32)
            .background(Color(hex: coverColor).opacity(0.12))
            .clipShape(Circle())
    }

    private var statusBadge: some View {
        Text(statusLabel)
            .scaledFont(10, .semibold)
            .foregroundColor(statusColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(statusColor.opacity(0.15))
            .clipShape(Capsule())
    }

    private var statusColor: Color {
        switch item.status {
        case "pending":   return .orange
        case "resolved":  return .green
        case "dismissed": return AppColors.textSecondary(.light)
        default:          return .gray
        }
    }

    private var statusLabel: String {
        switch item.status {
        case "pending":   return bundle.loc("Pending")
        case "resolved":  return bundle.loc("Resolved")
        case "dismissed": return bundle.loc("Dismissed")
        default:          return item.status.capitalized
        }
    }

    @ViewBuilder
    private var targetPreview: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(bundle.loc(item.targetType == "post" ? "Reported post" : "Reported member"))
                .scaledFont(12, .medium)
                .foregroundColor(AppColors.textTertiary(colorScheme))

            if let content = item.postContent {
                Text(content)
                    .scaledFont(14)
                    .foregroundColor(AppColors.textPrimary(colorScheme))
                    .lineLimit(4)
                    .padding(10)
                    .background(AppColors.elevated(colorScheme))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else if let member = item.memberInfo {
                HStack(spacing: 8) {
                    Circle()
                        .fill(Color(hex: member.avatarColor))
                        .frame(width: 28, height: 28)
                        .overlay(
                            Text(String(member.displayName.prefix(1)))
                                .scaledFont(12, .bold)
                                .foregroundColor(.white)
                        )
                    VStack(alignment: .leading, spacing: 1) {
                        Text(member.displayName)
                            .scaledFont(14, .medium)
                        Text("@\(member.username)")
                            .scaledFont(12)
                            .foregroundColor(AppColors.textSecondary(colorScheme))
                    }
                }
            }

            if let detail = item.detail, !detail.isEmpty {
                Text("\"\(detail)\"")
                    .scaledFont(13)
                    .foregroundColor(AppColors.textSecondary(colorScheme))
                    .italic()
            }
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 8) {
            if item.targetType == "post" {
                actionBtn(label: bundle.loc("Remove"), icon: "trash", color: .red, action: onRemove)
            } else {
                actionBtn(label: bundle.loc("Ban"),    icon: "person.crop.circle.badge.xmark", color: .red, action: onBan)
            }
            actionBtn(label: bundle.loc("Dismiss"), icon: "xmark", color: .gray, action: onDismiss)
            Spacer()
        }
    }

    private func actionBtn(label: String, icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(label, systemImage: icon)
                .scaledFont(13, .medium)
                .foregroundColor(color)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(color.opacity(0.1))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var reasonLabel: String {
        ReportReason(rawValue: item.reason)?.displayName ?? item.reason.capitalized
    }
}

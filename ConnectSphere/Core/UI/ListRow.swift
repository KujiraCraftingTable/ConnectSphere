import SwiftUI

// MARK: - List row
/// A settings/detail list row: a leading slot, a title (+ optional subtitle), a
/// trailing slot, an optional chevron. Replaces `SettingsView.settingsRow`,
/// `ChatSettingsView.SettingsRow`, `CommunityDetailView.memberRow`,
/// `ConversationRow`'s skeleton, etc.
struct ListRow<Leading: View, Trailing: View>: View {
    var title: String
    var subtitle: String? = nil
    var destructive: Bool = false
    var showsChevron: Bool = false
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var trailing: () -> Trailing

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: AppSpacing.md) {
            leading()

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .appFont(.body)
                    .foregroundStyle(destructive ? AppColors.danger(scheme) : AppColors.textPrimary(scheme))
                if let subtitle {
                    Text(subtitle)
                        .appFont(.footnote)
                        .foregroundStyle(AppColors.textSecondary(scheme))
                }
            }

            Spacer(minLength: 0)

            trailing()

            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(AppIcon.xs)
                    .foregroundStyle(AppColors.textTertiary(scheme))
            }
        }
        .padding(.vertical, AppSpacing.sm)
        .contentShape(Rectangle())
    }
}

// MARK: - Convenience inits
// Convenience initializers for the common shapes.
extension ListRow where Leading == EmptyView, Trailing == EmptyView {
    init(_ title: String, subtitle: String? = nil, destructive: Bool = false, showsChevron: Bool = false) {
        self.init(title: title, subtitle: subtitle, destructive: destructive,
                  showsChevron: showsChevron, leading: { EmptyView() }, trailing: { EmptyView() })
    }
}
extension ListRow where Trailing == EmptyView {
    init(_ title: String, subtitle: String? = nil, destructive: Bool = false, showsChevron: Bool = false,
         @ViewBuilder leading: @escaping () -> Leading) {
        self.init(title: title, subtitle: subtitle, destructive: destructive,
                  showsChevron: showsChevron, leading: leading, trailing: { EmptyView() })
    }
}

// MARK: - Settings icon tile
/// The iOS-Settings colored icon tile. Kept as a deliberate style, but
/// tokenised so callers stop passing raw hex.
struct SettingsIconTile: View {
    let systemName: String
    let color: Color
    var body: some View {
        Image(systemName: systemName)
            .font(AppIcon.sm)
            .foregroundStyle(.white)
            .frame(width: 28, height: 28)
            .background(color, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

import SwiftUI

struct CommunityCard: View {
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.appBundle) var bundle
    let community: Community
    let onToggle: () -> Void   // join or leave

    var body: some View {
        HStack(spacing: 12) {
            // Real uploaded photo when set, else the emoji/color fallback —
            // same Avatar component every user pfp already uses.
            Avatar(name: community.iconEmoji, colorHex: community.coverColor,
                   imageURL: community.avatarUrl, size: .lg)

            VStack(alignment: .leading, spacing: 3) {
                Text(community.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(AppColors.textPrimary(colorScheme))
                    .lineLimit(1)
                if let desc = community.description {
                    Text(desc)
                        .font(.system(size: 13))
                        .foregroundColor(AppColors.textSecondary(colorScheme))
                        .lineLimit(2)
                }
                Text(String(format: bundle.loc("%lld members"), community.memberCount))
                    .font(.system(size: 12))
                    .foregroundColor(AppColors.textTertiary(colorScheme))
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            joinButton
        }
        .padding(12)
        .surfaceBackground()
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.2 : 0.05), radius: 4, x: 0, y: 2)
    }

    private var joinButton: some View {
        Button(action: onToggle) {
            Text(community.isMember ? bundle.loc("Joined") : bundle.loc("Join"))
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(community.isMember ? AppColors.textSecondary(colorScheme) : .white)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(
                    community.isMember
                        ? AppColors.elevated(colorScheme)
                        : Color(hex: community.coverColor)
                )
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

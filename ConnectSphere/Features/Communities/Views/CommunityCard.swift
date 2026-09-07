import SwiftUI

struct CommunityCard: View {
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.appBundle) var bundle
    let community: Community
    let onToggle: () -> Void   // join or leave

    var body: some View {
        HStack(spacing: 12) {
            // Cover icon
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(hex: community.coverColor).opacity(0.18))
                    .frame(width: 52, height: 52)
                Text(community.iconEmoji)
                    .font(.system(size: 26))
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(community.name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(AppColors.textPrimary(colorScheme))
                        .lineLimit(1)
                    typeBadge
                }
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

    private var typeBadge: some View {
        Text(bundle.loc(community.type.label))
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(Color(hex: community.coverColor))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color(hex: community.coverColor).opacity(0.12))
            .clipShape(Capsule())
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

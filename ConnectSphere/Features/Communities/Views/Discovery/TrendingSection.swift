import SwiftUI

/// Horizontal scroll of trending community cards
struct TrendingSection: View {
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.appBundle) var bundle
    let communities: [Community]
    let onTap: (Community) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(bundle.loc("Trending Now"), icon: "flame.fill", color: AppColors.textSecondary(colorScheme))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(communities) { community in
                        Button { onTap(community) } label: {
                            communityChip(community)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private func communityChip(_ community: Community) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(hex: community.coverColor).opacity(0.18))
                    .frame(width: 64, height: 64)
                Text(community.iconEmoji)
                    .font(.system(size: 30))
            }
            Text(community.name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(AppColors.textPrimary(colorScheme))
                .lineLimit(1)
                .frame(width: 80)
            Text(String(format: bundle.loc("%d members"), community.memberCount))
                .font(.system(size: 11))
                .foregroundColor(AppColors.textTertiary(colorScheme))
        }
        .frame(width: 80)
    }

    private func sectionHeader(_ title: String, icon: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundColor(color)
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(AppColors.textPrimary(colorScheme))
        }
        .padding(.horizontal, 16)
    }
}

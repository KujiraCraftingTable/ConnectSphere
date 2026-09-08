import SwiftUI

/// Horizontal scroll of recommended community cards
struct RecommendedSection: View {
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.appBundle) var bundle
    let communities: [Community]
    let onTap: (Community) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(bundle.loc("Recommended For You"), icon: "sparkles", color: AppColors.textSecondary(colorScheme))

            if communities.isEmpty {
                Text(bundle.loc("Join some communities to get personalised recommendations"))
                    .font(.system(size: 14))
                    .foregroundColor(AppColors.textTertiary(colorScheme))
                    .padding(.horizontal, 16)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(communities) { community in
                            Button { onTap(community) } label: {
                                recommendationCard(community)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
        }
    }

    private func recommendationCard(_ community: Community) -> some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(hex: community.coverColor).opacity(0.18))
                    .frame(width: 44, height: 44)
                Text(community.iconEmoji).font(.system(size: 22))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(community.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(AppColors.textPrimary(colorScheme))
                    .lineLimit(1)
                Text(String(format: bundle.loc("%d members"), community.memberCount))
                    .font(.system(size: 11))
                    .foregroundColor(AppColors.textTertiary(colorScheme))
            }
        }
        .padding(10)
        .frame(width: 190, alignment: .leading)
        .surfaceBackground()
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.05), radius: 3, x: 0, y: 1)
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

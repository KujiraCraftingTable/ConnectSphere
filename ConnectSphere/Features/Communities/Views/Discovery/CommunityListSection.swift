import SwiftUI

/// A titled vertical list of community rows (Trending, Recommended).
struct CommunityListSection: View {
    @Environment(\.colorScheme) var colorScheme
    let title: String
    let icon: String
    let communities: [Community]
    /// Shown instead of rows when there are none; nil hides the section's body.
    var emptyText: String?
    let onTap: (Community) -> Void
    let onToggle: (Community) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: icon).foregroundColor(AppColors.textSecondary(colorScheme))
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(AppColors.textPrimary(colorScheme))
            }
            .padding(.horizontal, 16)

            if communities.isEmpty, let emptyText {
                Text(emptyText)
                    .font(.system(size: 14))
                    .foregroundColor(AppColors.textTertiary(colorScheme))
                    .padding(.horizontal, 16)
            }
            ForEach(communities) { community in
                Button { onTap(community) } label: {
                    CommunityRow(community: community) { onToggle(community) }
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
            }
        }
    }
}

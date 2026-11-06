import SwiftUI

/// A community page's header: the cover runs up under the status bar and the
/// navigation buttons, its top fading into the page so the clock and buttons
/// stay legible and its bottom edge left sharp; under it, a full-width card
/// with the name, privacy, member count and Join.
struct CommunityHeaderCard<Join: View>: View {
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.appBundle) private var bundle
    @Environment(\.colorScheme) private var colorScheme

    let community: Community
    /// Height of the bars above the page (status bar + navigation bar); the
    /// cover grows by this much so it reaches the top of the screen.
    let topInset: CGFloat
    /// The name opens "About this community", like Facebook.
    let onInfo: () -> Void
    @ViewBuilder let join: () -> Join

    /// The cover's height below the bars.
    static var visibleCoverHeight: CGFloat { 190 }

    var body: some View {
        VStack(spacing: 0) {
            cover
            card
        }
    }

    private var coverHeight: CGFloat { topInset + Self.visibleCoverHeight }

    // MARK: Cover

    private var cover: some View {
        CommunityCover(community: community, emojiSize: 56)
            .background(AppColors.surface(colorScheme))
            .frame(height: coverHeight)
            .frame(maxWidth: .infinity)
            .clipped()
            .overlay(alignment: .top) {
                LinearGradient(
                    colors: [AppColors.base(colorScheme).opacity(0.85), AppColors.base(colorScheme).opacity(0)],
                    startPoint: .top, endPoint: .bottom)
                    .frame(height: topInset)
                    .allowsHitTesting(false)
            }
    }

    // MARK: Card

    private var card: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: onInfo) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(community.name)
                        .scaledFont(24, .bold)
                        .foregroundColor(AppColors.textPrimary(colorScheme))
                        .multilineTextAlignment(.leading)
                    Image(systemName: "chevron.right")
                        .scaledFont(15, .semibold)
                        .foregroundColor(AppColors.textSecondary(colorScheme))
                }
            }
            .buttonStyle(.plain)

            HStack(spacing: 5) {
                Image(systemName: community.privacy == .private ? "lock.fill" : "globe")
                Text(community.privacy == .private ? bundle.loc("Private") : bundle.loc("Public"))
                Text("·")
                Text(String(format: bundle.loc("%lld members"), community.memberCount))
            }
            .scaledFont(14)
            .foregroundColor(AppColors.textSecondary(colorScheme))

            if let about = community.description?.trimmingCharacters(in: .whitespacesAndNewlines), !about.isEmpty {
                // The rest is in "About this community" (the name opens it).
                Text(community.isDescriptionMarkdown
                     ? MarkdownFormatter.attributed(about, linkColor: themeManager.theme.primary,
                                                    quoteColor: AppColors.textSecondary(colorScheme))
                     : AttributedString(about))
                    .scaledFont(15)
                    .foregroundColor(AppColors.textPrimary(colorScheme))
                    .lineLimit(4)
                    .multilineTextAlignment(.leading)
                    .padding(.top, 2)
            }

            join()
        }
        .padding(.horizontal, AppSpacing.lg)
        .padding(.vertical, AppSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColors.surface(colorScheme))
    }
}

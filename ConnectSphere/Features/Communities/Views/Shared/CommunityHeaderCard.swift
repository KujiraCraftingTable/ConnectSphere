import SwiftUI

/// A community page's header: the cover runs up under the status bar and the
/// navigation buttons, its top fading into the page so the clock and buttons
/// stay legible and its bottom dissolving into a blurred copy of itself; under
/// it, a full-width card with the name, privacy, member count and Join.
struct CommunityHeaderCard<Join: View>: View {
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

    /// The placeholder colour is see-through, and an opaque blur drops its
    /// alpha (showing it at full strength); flattening it onto an opaque base
    /// first keeps its own light tint in the blurred copy.
    private var artwork: some View {
        CommunityCover(community: community, emojiSize: 56)
            .background(AppColors.surface(colorScheme))
            .compositingGroup()
    }

    // MARK: Cover

    private var cover: some View {
        artwork
            .frame(height: coverHeight)
            .frame(maxWidth: .infinity)
            .mask(LinearGradient(stops: [
                .init(color: .black, location: 0.82),
                .init(color: .clear, location: 1),
            ], startPoint: .top, endPoint: .bottom))
            // A soft copy behind it, for its bottom edge to dissolve into.
            .background {
                artwork
                    .blur(radius: 12, opaque: true)
                    .clipped()
                    .accessibilityHidden(true)
            }
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
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(AppColors.textPrimary(colorScheme))
                        .multilineTextAlignment(.leading)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 15, weight: .semibold))
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
            .font(.system(size: 14))
            .foregroundColor(AppColors.textSecondary(colorScheme))

            if let about = community.description?.trimmingCharacters(in: .whitespacesAndNewlines), !about.isEmpty {
                // The rest is in "About this community" (the name opens it).
                Text(about)
                    .font(.system(size: 15))
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

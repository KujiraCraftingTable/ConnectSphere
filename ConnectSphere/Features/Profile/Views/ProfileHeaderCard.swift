import SwiftUI

/// The counts under a profile's name; each opens its list.
enum ProfileStat {
    case posts, friends, followers, following
}

/// A profile's whole header as one component, on a `CoverHeader` (the cover
/// under the status bar, its reflection behind a floating rounded card).
/// The card holds a large centred
/// avatar, name, job, the four counts, the full bio, this mode's interests or
/// skills, and the action buttons.
/// Shared by your own `ProfileView` and other people's `UserProfileView`.
struct ProfileHeaderCard<Actions: View>: View {
    @Environment(\.openURL) private var openURL
    @State private var inAppBrowserURL: URL?
    @Environment(\.appBundle) private var bundle
    @Environment(\.colorScheme) private var colorScheme
    @Environment(ThemeManager.self) private var themeManager

    let user: UserProfile
    let mode: AppMode
    var onStatTap: (ProfileStat) -> Void = { _ in }
    /// The round button at the card's top-right that flips to the person's
    /// other persona (and back).
    var flip: Flip? = nil
    @ViewBuilder let actions: () -> Actions

    struct Flip {
        /// The mode the button goes to.
        let to: AppMode
        let action: () -> Void
    }

    private let avatarSize: CGFloat = 132
    private let cardRadius: CGFloat = 24

    var body: some View {
        CoverHeader(coverUrl: user.coverUrl) { sheet }
    }

    // MARK: Sheet

    private var sheet: some View {
        VStack(spacing: 12) {
            AvatarView(user: user, size: avatarSize)
                .overlay(Circle().stroke(AppColors.surface(colorScheme), lineWidth: 5))
                .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
                .padding(.top, -avatarSize / 2)

            identity
            if user.lockedOut { lockedNote } else { stats }
            if !user.bio.isEmpty {
                Text(user.isBioMarkdown
                     ? MarkdownFormatter.attributed(user.bio, linkColor: themeManager.theme.primary,
                                                    quoteColor: AppColors.textSecondary(colorScheme))
                     : AttributedString(user.bio))
                    .scaledFont(15)
                    .foregroundColor(AppColors.textPrimary(colorScheme))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)   // always in full
                    .environment(\.openURL, OpenURLAction { url in
                        if let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
                            inAppBrowserURL = url
                        } else {
                            openURL(url)
                        }
                        return .handled
                    })
                    .inAppBrowser(url: $inAppBrowserURL)
            }
            tags
            actions()
                .padding(.top, 4)
        }
        .padding(.horizontal, AppSpacing.lg)
        .padding(.bottom, AppSpacing.lg)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .topTrailing) { if let flip { FlipButton(flip: flip) } }
        .overlay(alignment: .topLeading) { if user.isLocked { lockedBadge } }
        .background(AppColors.surface(colorScheme),
                    in: RoundedRectangle(cornerRadius: cardRadius, style: .continuous))
        .shadow(color: AppElevation.overlay.color(colorScheme), radius: AppElevation.overlay.radius,
                y: AppElevation.overlay.y)
    }

    private var identity: some View {
        VStack(spacing: 4) {
            Text(user.name)
                .scaledFont(26, .bold)
                .foregroundColor(AppColors.textPrimary(colorScheme))
                .multilineTextAlignment(.center)
            // The same on both personas: it's the account's handle.
            if !user.username.isEmpty {
                Text("@\(user.username)")
                    .scaledFont(15)
                    .foregroundColor(AppColors.textSecondary(colorScheme))
                    .textSelection(.enabled)
            }
            if let job = jobLine {
                Text(job)
                    .scaledFont(15)
                    .foregroundColor(AppColors.textSecondary(colorScheme))
                    .multilineTextAlignment(.center)
            }
            if let location = user.location, !location.isEmpty {
                Label(location, systemImage: "mappin.and.ellipse")
                    .scaledFont(13)
                    .foregroundColor(AppColors.textSecondary(colorScheme))
            }
        }
    }

    /// Top-left of the card, where it's seen first, in the theme colour.
    private var lockedBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: "lock.fill")
            Text("Locked profile", bundle: bundle)
        }
        .scaledFont(11, .semibold)
        .lineLimit(1)
        .foregroundColor(themeManager.theme.primary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(themeManager.theme.primary.opacity(0.14), in: Capsule())
        // The switch button's height and padding, so both sit on one centre line.
        .frame(height: 38)
        .padding(12)
    }

    /// "iOS dev · Kujira corp", or whichever half is set.
    /// Work only, Hobby never talks about work.
    private var jobLine: String? {
        guard mode == .work else { return nil }
        let parts = [user.jobTitle, user.company].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// What a locked-out viewer sees instead of the counts.
    private var lockedNote: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.shield.fill")
                .scaledFont(22)
                .foregroundColor(AppColors.textSecondary(colorScheme))
            Text(String(format: bundle.loc(mode == .work
                    ? "%@ locked their profile. Only their connections can see their posts and details."
                    : "%@ locked their profile. Only their friends can see their posts and details."), user.name))
                .scaledFont(14)
                .foregroundColor(AppColors.textSecondary(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColors.elevated(colorScheme), in: RoundedRectangle(cornerRadius: 14))
    }

    private var stats: some View {
        HStack(spacing: 0) {
            stat(user.postCount, bundle.loc("Posts"), .posts)
            stat(user.connectionCount, bundle.loc(mode == .hobby ? "Friends" : "Connections"), .friends)
            stat(user.followerCount, bundle.loc("Followers"), .followers)
            stat(user.followingCount, bundle.loc("Following"), .following)
        }
        .padding(.vertical, 4)
    }

    private func stat(_ count: Int, _ label: String, _ kind: ProfileStat) -> some View {
        Button { onStatTap(kind) } label: {
            VStack(spacing: 2) {
                Text("\(count)")
                    .scaledFont(18, .bold)
                    .foregroundColor(AppColors.textPrimary(colorScheme))
                Text(label)
                    .scaledFont(12)
                    .foregroundColor(AppColors.textSecondary(colorScheme))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("\(count) \(label)"))
    }

    /// Interests in Hobby. Work skills have their own section below, with
    /// their endorsements (`SkillsSection`).
    @ViewBuilder
    private var tags: some View {
        let items = mode == .hobby ? user.interests : []
        if !items.isEmpty {
            let row = HStack(spacing: AppSpacing.sm) {
                ForEach(items, id: \.self) { Chip(text: $0, style: .neutral) }
            }
            // Always one line: centred when it fits, otherwise it scrolls
            // sideways instead of wrapping onto more lines. Clipped to the
            // card's padding, so chips never slide out over the cover.
            ViewThatFits(in: .horizontal) {
                row
                ScrollView(.horizontal, showsIndicators: false) { row }
            }
            .padding(.top, 4)
        }
    }
}

/// The two wide buttons at the bottom of the header card.
struct ProfileCardButton: View {
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.colorScheme) private var colorScheme

    let title: String
    let icon: String
    var prominent = false
    var isLoading = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if isLoading {
                    ProgressView().scaleEffect(0.8).tint(prominent ? .white : nil)
                } else {
                    Image(systemName: icon).scaledFont(14, .semibold)
                }
                Text(title)
                    .scaledFont(15, .semibold)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .foregroundColor(prominent ? .white : AppColors.textPrimary(colorScheme))
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(prominent ? themeManager.theme.primary : AppColors.elevated(colorScheme),
                        in: RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
    }
}

/// The card's corner button: the other mode's icon, flipping to it.
struct FlipButton<Actions: View>: View {
    @Environment(\.appBundle) private var bundle
    @Environment(\.colorScheme) private var colorScheme
    @Environment(ThemeManager.self) private var themeManager
    let flip: ProfileHeaderCard<Actions>.Flip

    var body: some View {
        Button(action: flip.action) {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: flip.to.glyph)
                    .scaledFont(15, .semibold)
                    .foregroundColor(themeManager.theme.primary)
                    .frame(width: 38, height: 38)
                    .background(AppColors.elevated(colorScheme), in: Circle())
                Image(systemName: "arrow.triangle.2.circlepath")
                    .scaledFont(9, .bold)
                    .foregroundColor(.white)
                    .padding(3)
                    .background(themeManager.theme.primary, in: Circle())
                    .offset(x: 2, y: 2)
            }
        }
        .buttonStyle(.plain)
        .padding(12)
        .accessibilityLabel(Text(bundle.loc(flip.to == .work ? "See Work profile" : "See Hobby profile")))
    }
}

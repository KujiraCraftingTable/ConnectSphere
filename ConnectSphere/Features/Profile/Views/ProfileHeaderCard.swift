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
    private let interestNames = InterestNames.shared
    @Environment(\.colorScheme) private var colorScheme
    @Environment(ThemeManager.self) private var themeManager
    @Environment(AppState.self) private var appState

    let user: UserProfile
    let mode: AppMode
    var onStatTap: (ProfileStat) -> Void = { _ in }
    /// The round button at the card's top-right that flips to the person's
    /// other persona (and back).
    var flip: Flip? = nil
    /// Makes the "Locked profile" badge a button (your own profile only).
    var onLockedBadgeTap: (() -> Void)? = nil
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
            stats
            if user.lockedOut { lockedNote }
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

    /// HR is a Work identity: never shown on a Hobby profile. Your own
    /// profile comes from /me, which doesn't carry it, so AppState's is used.
    private var hrCompany: String? {
        guard mode == .work else { return nil }
        return user.hrCompany ?? (user.id == appState.currentUser?.id ? appState.hrCompany : nil)
    }

    private var identity: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Text(user.name)
                    .scaledFont(26, .bold)
                    .foregroundColor(AppColors.textPrimary(colorScheme))
                    .multilineTextAlignment(.center)
                if user.isOfficial { OfficialBadge().padding(.leading, -3) }
            }
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
            if let company = hrCompany { HRBadge(company: company) }
            if let location = user.location, !location.isEmpty {
                Label(location, systemImage: "mappin.and.ellipse")
                    .scaledFont(13)
                    .foregroundColor(AppColors.textSecondary(colorScheme))
            }
        }
    }

    /// Top-left of the card, where it's seen first, in the theme colour.
    @ViewBuilder
    private var lockedBadge: some View {
        if let onLockedBadgeTap {
            Button(action: onLockedBadgeTap) { lockedBadgeLabel }
                .buttonStyle(.plain)
        } else {
            lockedBadgeLabel
        }
    }

    /// Just the lock, in the same 38-point circle (the interest chips' grey,
    /// like the switch, so the corners match the chips below) and corner padding as the
    /// Hobby/Work switch on the other side, so the two sit on one line.
    private var lockedBadgeLabel: some View {
        Image(systemName: "lock.fill")
            // A lock is narrower than the briefcase opposite, so it's drawn larger
            // to look the same size.
            .scaledFont(20, .semibold)
            .foregroundColor(themeManager.theme.primary)
            .frame(width: 38, height: 38)
            .background(AppColors.textPrimary(colorScheme).opacity(colorScheme == .dark ? 0.16 : 0.08), in: Circle())
            .padding(12)
            .accessibilityLabel(Text("Locked profile", bundle: bundle))
    }

    /// "iOS dev · Kujira corp", or whichever half is set.
    /// Work only, Hobby never talks about work.
    private var jobLine: String? {
        guard mode == .work else { return nil }
        let parts = [user.jobTitle, user.company].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Under the counts for a locked-out viewer: why they don't open.
    private var lockedNote: some View {
        Label {
            Text(String(format: bundle.loc(mode == .work
                    ? "Only connections can see %@'s posts and lists."
                    : "Only friends can see %@'s posts and lists."), user.name))
        } icon: {
            Image(systemName: "lock.fill")
        }
        .scaledFont(12)
        .foregroundColor(AppColors.textSecondary(colorScheme))
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var stats: some View {
        HStack(spacing: 0) {
            stat(user.postCount, bundle.loc("Posts"), .posts)
            // The official account has followers only: no friends, follows no one.
            if !user.isOfficial {
                stat(user.connectionCount, bundle.loc(mode == .hobby ? "Friends" : "Connections"), .friends)
            }
            stat(user.followerCount, bundle.loc("Followers"), .followers)
            if !user.isOfficial {
                stat(user.followingCount, bundle.loc("Following"), .following)
            }
        }
        .padding(.vertical, 4)
    }

    /// A locked-out viewer sees the real counts, but the lists behind them
    /// stay closed (the server returns them empty), so they aren't buttons.
    @ViewBuilder
    private func stat(_ count: Int, _ label: String, _ kind: ProfileStat) -> some View {
        if user.lockedOut {
            statLabel(count, label)
                .accessibilityElement(children: .combine)
        } else {
            Button { onStatTap(kind) } label: { statLabel(count, label) }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("\(count) \(label)"))
        }
    }

    private func statLabel(_ count: Int, _ label: String) -> some View {
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

    /// Interests in Hobby. Work skills have their own section below, with
    /// their endorsements (`SkillsSection`).
    @ViewBuilder
    private var tags: some View {
        let items = mode == .hobby ? user.interests : []
        if !items.isEmpty {
            let row = HStack(spacing: AppSpacing.sm) {
                ForEach(items, id: \.self) { Chip(text: interestNames.displayName($0, in: bundle), style: .neutral) }
            }
            // Always one line: centred when it fits, otherwise it scrolls
            // sideways instead of wrapping onto more lines. Clipped to the
            // card's padding, so chips never slide out over the cover.
            ViewThatFits(in: .horizontal) {
                row
                ScrollView(.horizontal, showsIndicators: false) { row }
            }
            .padding(.top, 4)
            .task { await interestNames.loadIfNeeded() }
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
                    .background(AppColors.textPrimary(colorScheme).opacity(colorScheme == .dark ? 0.16 : 0.08), in: Circle())
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

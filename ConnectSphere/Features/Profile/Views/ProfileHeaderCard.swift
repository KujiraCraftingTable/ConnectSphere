import SwiftUI

/// The counts under a profile's name; each opens its list.
enum ProfileStat {
    case posts, friends, followers, following
}

/// A profile's whole header as one component, Facebook-style: the cover runs
/// edge to edge up under the status bar (its top fades into the page so the
/// clock and nav buttons stay legible) and stays sharp to its bottom edge,
/// where a mirrored, softly blurred reflection of it carries on behind a
/// floating rounded card — inset like the post cards — and fades to the page
/// colour by the card's bottom. The card holds a large centred
/// avatar, name, job, the four counts, the full bio, this mode's interests or
/// skills, and the action buttons.
/// Shared by your own `ProfileView` and other people's `UserProfileView`.
struct ProfileHeaderCard<Actions: View>: View {
    @Environment(\.appBundle) private var bundle
    @Environment(\.colorScheme) private var colorScheme

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
    /// How far the card rises over the cover's bottom. 0 = the whole framed
    /// cover stays visible (only the avatar overlaps it), so the photo reads big.
    private let cardOverlap: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            cover
            sheet
                .padding(.horizontal, AppSpacing.sm)    // same inset as the post cards
                .padding(.top, -cardOverlap)
                .padding(.bottom, AppSpacing.md)        // a strip of faded cover under the card
        }
        .background(alignment: .top) {
            VStack(spacing: 0) {
                // A soft copy of the cover behind it, for its bottom to dissolve into.
                CoverPhotoView(coverUrl: user.coverUrl)
                    .blur(radius: 12, opaque: true)
                coverExtension
                // The strip under the card stays clear: the fade ends with the card.
                Color.clear.frame(height: AppSpacing.md)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    // MARK: Cover extension

    /// The cover's continuation behind the card. The saved cover is exactly
    /// 3 : 2, so there's no more photo below its edge: this mirrors it (its
    /// top row is the photo's bottom row, so it carries on without a seam),
    /// blurs it softly and fades it out by the card's bottom — what shows in
    /// the margins beside the card. The sharp cover's bottom dissolves into a
    /// soft copy of itself just above (see `cover`), so there's no line where
    /// sharp turns soft.
    private var coverExtension: some View {
        Color.clear
            .overlay { CoverArtwork(coverUrl: user.coverUrl, stretch: true) }
            .scaleEffect(x: 1, y: -1)
            .blur(radius: 12, opaque: true)
            .mask(LinearGradient(stops: [
                .init(color: .black, location: 0),
                .init(color: .black.opacity(0.55), location: 0.45),
                .init(color: .clear, location: 1),
            ], startPoint: .top, endPoint: .bottom))
            .clipped()
    }

    // MARK: Cover

    /// The framed cover as cropped, its top fading into the page so the clock
    /// and buttons stay legible. Its bottom dissolves into a soft copy of itself behind it.
    private var cover: some View {
        CoverPhotoView(coverUrl: user.coverUrl)
            .mask(LinearGradient(stops: [
                .init(color: .black, location: 0.82),
                .init(color: .clear, location: 1),
            ], startPoint: .top, endPoint: .bottom))
            .overlay(alignment: .top) {
                GeometryReader { geo in
                    LinearGradient(
                        colors: [AppColors.base(colorScheme).opacity(0.85), AppColors.base(colorScheme).opacity(0)],
                        startPoint: .top, endPoint: .bottom)
                        .frame(height: geo.size.height * CoverPhotoView.fadedTopFraction)
                }
                .allowsHitTesting(false)
            }
            .accessibilityHidden(true)
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
                Text(user.bio)
                    .font(.system(size: 15))
                    .foregroundColor(AppColors.textPrimary(colorScheme))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)   // always in full
            }
            tags
            actions()
                .padding(.top, 4)
        }
        .padding(.horizontal, AppSpacing.lg)
        .padding(.bottom, AppSpacing.lg)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .topTrailing) { if let flip { FlipButton(flip: flip) } }
        .background(AppColors.surface(colorScheme),
                    in: RoundedRectangle(cornerRadius: cardRadius, style: .continuous))
        .shadow(color: AppElevation.overlay.color(colorScheme), radius: AppElevation.overlay.radius,
                y: AppElevation.overlay.y)
    }

    private var identity: some View {
        VStack(spacing: 4) {
            Text(user.name)
                .font(.system(size: 26, weight: .bold))
                .foregroundColor(AppColors.textPrimary(colorScheme))
                .multilineTextAlignment(.center)
            // The same on both personas: it's the account's handle.
            if !user.username.isEmpty {
                Text("@\(user.username)")
                    .font(.system(size: 15))
                    .foregroundColor(AppColors.textSecondary(colorScheme))
                    .textSelection(.enabled)
            }
            if user.isLocked {
                HStack(spacing: 4) {
                    Image(systemName: "lock.fill")
                    Text("Locked profile", bundle: bundle)
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(AppColors.textSecondary(colorScheme))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(AppColors.elevated(colorScheme), in: Capsule())
            }
            if let job = jobLine {
                Text(job)
                    .font(.system(size: 15))
                    .foregroundColor(AppColors.textSecondary(colorScheme))
                    .multilineTextAlignment(.center)
            }
            if let location = user.location, !location.isEmpty {
                Label(location, systemImage: "mappin.and.ellipse")
                    .font(.system(size: 13))
                    .foregroundColor(AppColors.textSecondary(colorScheme))
            }
        }
    }

    /// "iOS dev · Kujira corp", or whichever half is set.
    /// Work only — Hobby never talks about work.
    private var jobLine: String? {
        guard mode == .work else { return nil }
        let parts = [user.jobTitle, user.company].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// What a locked-out viewer sees instead of the counts.
    private var lockedNote: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 22))
                .foregroundColor(AppColors.textSecondary(colorScheme))
            Text(String(format: bundle.loc(mode == .work
                    ? "%@ locked their profile. Only their connections can see their posts and details."
                    : "%@ locked their profile. Only their friends can see their posts and details."), user.name))
                .font(.system(size: 14))
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
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(AppColors.textPrimary(colorScheme))
                Text(label)
                    .font(.system(size: 12))
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
            // sideways instead of wrapping onto more lines.
            ViewThatFits(in: .horizontal) {
                row
                ScrollView(.horizontal, showsIndicators: false) { row }
                    .scrollClipDisabled()
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
                    Image(systemName: icon).font(.system(size: 14, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
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
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(themeManager.theme.primary)
                    .frame(width: 38, height: 38)
                    .background(AppColors.elevated(colorScheme), in: Circle())
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 9, weight: .bold))
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

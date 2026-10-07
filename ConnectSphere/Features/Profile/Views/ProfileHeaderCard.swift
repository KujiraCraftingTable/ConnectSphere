import SwiftUI

/// The counts under a profile's name; each opens its list.
enum ProfileStat {
    case posts, friends, followers, following
}

/// A profile's whole header as one component, Facebook-style: the cover runs
/// edge to edge up under the status bar (its top fades into the page so the
/// clock and nav buttons stay legible) and stays sharp down to a blurred copy
/// of itself that carries on behind a floating rounded card — inset like the post cards —
/// fading to the page colour just below it. The card holds a large centred
/// avatar, name, job, the four counts, the full bio, this mode's interests or
/// skills, and the action buttons.
/// Shared by your own `ProfileView` and other people's `UserProfileView`.
struct ProfileHeaderCard<Actions: View>: View {
    @Environment(\.appBundle) private var bundle
    @Environment(\.colorScheme) private var colorScheme

    let user: UserProfile
    let mode: AppMode
    var onStatTap: (ProfileStat) -> Void = { _ in }
    @ViewBuilder let actions: () -> Actions

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
        .background(alignment: .top) { backdrop }
    }

    // MARK: Backdrop

    /// The cover again, heavily blurred so stretching it can't look pixelated
    /// or mis-framed, filling the whole header and fading out by its bottom —
    /// what shows in the margins around the card.
    private var backdrop: some View {
        Color.clear
            .overlay { CoverArtwork(coverUrl: user.coverUrl) }
            .blur(radius: 40, opaque: true)
            .mask(LinearGradient(stops: [
                .init(color: .black, location: 0),
                .init(color: .black.opacity(0.6), location: 0.5),
                .init(color: .clear, location: 1),
            ], startPoint: .top, endPoint: .bottom))
            .clipped()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    // MARK: Cover

    /// The framed cover, exactly as cropped and sharp right down to the card.
    private var cover: some View {
        CoverPhotoView(coverUrl: user.coverUrl)
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
            stats
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
    private var jobLine: String? {
        let parts = [user.jobTitle, user.company].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
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

    /// Interests in Hobby, skills in Work — each persona shows its own world.
    @ViewBuilder
    private var tags: some View {
        let items = mode == .hobby ? user.interests : user.skills
        if !items.isEmpty {
            FlowLayout(spacing: AppSpacing.sm, centered: true) {
                ForEach(items, id: \.self) { Chip(text: $0, style: .neutral) }
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

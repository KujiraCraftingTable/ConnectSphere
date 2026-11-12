import SwiftUI

/// A seller as the Marketplace shows them. Opened by tapping the seller on
/// an item. Like a community member's profile: the profile card, their
/// check-legit post (buyers' reviews, never shown on the profile), then their
/// items in the community you came from and their other items.
struct MarketplaceSellerView: View {
    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.appBundle) private var bundle
    @Environment(\.colorScheme) private var colorScheme

    @State private var viewModel: MarketplaceSellerViewModel
    /// The check-legit post's page, opened from its card.
    @State private var legitRoute: PostRoute?
    @State private var editingProfile = false

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
    private var token: String { appState.authToken ?? "" }

    init(seller: UserProfile, mode: AppMode, communities: [ListingData.ListedIn] = []) {
        _viewModel = State(initialValue: MarketplaceSellerViewModel(seller: seller, mode: mode,
                                                                    communities: communities))
    }


    var body: some View {
        ScrollView {
            VStack(spacing: AppSpacing.md) {
                header
                if let post = viewModel.legit?.post { legitCard(post) }
                if let title = viewModel.nearbyTitle, !viewModel.nearby.isEmpty {
                    sectionTitle(title)
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(viewModel.nearby) { post in ListingCard(post: post) }
                    }
                    .padding(.horizontal, AppSpacing.lg)
                }
                if viewModel.items.isEmpty && viewModel.nearby.isEmpty && !viewModel.isLoading {
                    Text("No items listed", bundle: bundle)
                        .scaledFont(14)
                        .foregroundColor(AppColors.textTertiary(colorScheme))
                        .padding(.top, 30)
                } else if !viewModel.items.isEmpty {
                    if !viewModel.nearby.isEmpty { sectionTitle(bundle.loc("Other listings")) }
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(viewModel.items) { post in
                            ListingCard(post: post)
                                .task { if post.id == viewModel.items.last?.id { await viewModel.loadMore(token: token) } }
                        }
                    }
                    .padding(.horizontal, AppSpacing.lg)
                }
                if viewModel.isLoading { ProgressView().padding() }
            }
            .padding(.bottom, AppSpacing.lg)
        }
        // The cover runs up under the status bar, as on a profile.
        .ignoresSafeArea(edges: .top)
        .appBackground()
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .task { await viewModel.load(token: token) }
        .navigationDestination(item: $legitRoute) { route in
            PostDetailView(postId: route.postId, focusComposer: route.focusComposer)
        }
        .sheet(isPresented: $editingProfile) {
            if let profile = viewModel.profile {
                EditMarketplaceProfileView(profile: profile) { viewModel.replaceProfile($0) }
            }
        }
        .alert(bundle.loc("Error"), isPresented: Binding(get: { viewModel.errorMessage != nil },
                                                          set: { if !$0 { viewModel.errorMessage = nil } })) {
            Button(bundle.loc("OK")) {}
        } message: { Text(viewModel.errorMessage ?? "") }
    }

    /// The same cover and floating card as a community member's profile.
    private var header: some View {
        let seller = viewModel.seller
        return CoverHeader(coverUrl: viewModel.coverUrl) {
            VStack(spacing: 12) {
                Avatar(name: viewModel.displayName, colorHex: seller.avatarColor, imageURL: viewModel.avatarUrl,
                       diameter: 132)
                    .overlay(Circle().stroke(AppColors.surface(colorScheme), lineWidth: 5))
                    .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
                    .padding(.top, -66)

                VStack(spacing: 4) {
                    Text(viewModel.displayName)
                        .scaledFont(26, .bold)
                        .foregroundColor(AppColors.textPrimary(colorScheme))
                        .multilineTextAlignment(.center)
                    if !seller.username.isEmpty {
                        Text("@\(seller.username)")
                            .scaledFont(15)
                            .foregroundColor(AppColors.textSecondary(colorScheme))
                    }
                    if let bio = viewModel.profile?.bio, !bio.isEmpty {
                        Text(bio)
                            .scaledFont(15)
                            .foregroundColor(AppColors.textPrimary(colorScheme))
                            .multilineTextAlignment(.center)
                            .padding(.top, 4)
                    }
                    if let location = seller.location, !location.isEmpty {
                        Label(location, systemImage: "mappin.and.ellipse")
                            .scaledFont(14)
                            .foregroundColor(AppColors.textSecondary(colorScheme))
                    }
                }

                HStack(spacing: 40) {
                    stat(viewModel.listedCount, bundle.loc("items listed"))
                    if let profile = viewModel.profile {
                        stat(profile.followerCount, bundle.loc(profile.followerCount == 1 ? "follower" : "followers"))
                    }
                }
                .padding(.vertical, 4)

                if viewModel.profile != nil { profileButton }
            }
            .padding(.horizontal, AppSpacing.lg)
            .padding(.bottom, AppSpacing.lg)
            .frame(maxWidth: .infinity)
            // Buyers' rating from the check-legit post (hidden with it), and
            // the Legit badge once it's earned.
            .overlay(alignment: .topLeading) {
                if viewModel.legit?.post != nil {
                    LegitRatingStack(average: viewModel.legit?.ratingAverage,
                                     count: viewModel.legit?.ratingCount ?? 0)
                        .padding(14)
                }
            }
            .overlay(alignment: .topTrailing) {
                if viewModel.legit?.isLegit == true { LegitBadge().padding(14) }
            }
            .background(AppColors.surface(colorScheme),
                        in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .shadow(color: AppElevation.overlay.color(colorScheme), radius: AppElevation.overlay.radius,
                    y: AppElevation.overlay.y)
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .scaledFont(17, .semibold)
            .foregroundColor(AppColors.textPrimary(colorScheme))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, AppSpacing.lg)
            .padding(.top, AppSpacing.sm)
    }

    private func stat(_ value: Int, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text("\(value)")
                .scaledFont(18, .bold)
                .foregroundColor(AppColors.textPrimary(colorScheme))
            Text(label)
                .scaledFont(12)
                .foregroundColor(AppColors.textSecondary(colorScheme))
        }
        .accessibilityElement(children: .combine)
    }

    private var isOwnPage: Bool { appState.currentUser?.id.lowercased() == viewModel.seller.id.lowercased() }

    /// Your own page edits your Marketplace profile; anyone else's follows it.
    /// No way to the personal profile: selling stays apart from it.
    @ViewBuilder
    private var profileButton: some View {
        if isOwnPage {
            Button { editingProfile = true } label: {
                Text("Edit marketplace profile", bundle: bundle)
                    .scaledFont(15, .semibold)
                    .foregroundColor(themeManager.theme.primary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, AppSpacing.sm + 2)
                    .background(themeManager.theme.primary.opacity(0.12),
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        } else {
            let following = viewModel.profile?.isFollowing == true
            Button { Task { await viewModel.toggleFollow(token: token) } } label: {
                Label { Text(following ? "Following" : "Follow", bundle: bundle) }
                      icon: { Image(systemName: following ? "checkmark" : "plus") }
                    .scaledFont(15, .semibold)
                    .foregroundColor(following ? themeManager.theme.primary : .white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, AppSpacing.sm + 2)
                    .background(following ? themeManager.theme.primary.opacity(0.12) : themeManager.theme.primary,
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isTogglingFollow)
            .padding(.top, 4)
        }
    }

    /// The seller's check-legit post, shown like any post (its own menu edits
    /// or hides it); the buyers' rating sits on the seller card above.
    private func legitCard(_ post: Post) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            PostCard(post: post,
                     onPostUpdated: { viewModel.replaceLegitPost($0) },
                     onOpenDetail: { focus in legitRoute = PostRoute(postId: post.id, focusComposer: focus) },
                     showConnectButton: false)
                .cardStyle()
                .padding(.horizontal, AppSpacing.sm)
        }
    }
}

/// The seller's Legit badge: a high rating over many reviews.
struct LegitBadge: View {
    @Environment(\.appBundle) private var bundle
    var body: some View {
        Label { Text("Legit", bundle: bundle) } icon: { Image(systemName: "checkmark.seal.fill") }
            .scaledFont(13, .bold)
            .foregroundColor(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.green, in: Capsule())
            .accessibilityLabel(Text("Legit seller", bundle: bundle))
    }
}

/// The rating in the seller card's corner: three stars over two, the
/// average under them. No number until someone has reviewed.
struct LegitRatingStack: View {
    @Environment(\.appBundle) private var bundle
    @Environment(\.colorScheme) private var colorScheme
    let average: Double?
    let count: Int

    private var rating: Double { count > 0 ? (average ?? 0) : 0 }

    private static let starColor = Color(red: 1.0, green: 0.8, blue: 0.0)

    var body: some View {
        VStack(spacing: 3) {
            HStack(spacing: 2) { ForEach(1...3, id: \.self) { star($0) } }
            HStack(spacing: 2) { ForEach(4...5, id: \.self) { star($0) } }
            if count > 0 {
                Text(String(format: "%.1f", rating))
                    .scaledFont(14, .semibold)
                    .foregroundColor(AppColors.textPrimary(colorScheme))
            }
        }
        .accessibilityElement()
        .accessibilityLabel(count > 0
            ? Text(String(format: bundle.loc("Rated %@ of 5 stars"), String(format: "%.1f", rating)))
            : Text("No reviews yet", bundle: bundle))
    }

    private func star(_ i: Int) -> some View {
        let filled = rating >= Double(i) - 0.25
        let half = !filled && rating >= Double(i) - 0.75
        return Image(systemName: filled ? "star.fill" : (half ? "star.leadinghalf.filled" : "star"))
            .font(.system(size: 15))
            .foregroundColor(Self.starColor)
    }
}

/// Five stars, filled to `rating` (halves round to a half star).
struct StarRow: View {
    let rating: Double
    var size: CGFloat = 13
    var body: some View {
        HStack(spacing: 1) {
            ForEach(1...5, id: \.self) { i in
                let filled = rating >= Double(i) - 0.25
                let half = !filled && rating >= Double(i) - 0.75
                Image(systemName: filled ? "star.fill" : (half ? "star.leadinghalf.filled" : "star"))
                    .font(.system(size: size))
                    .foregroundColor(.orange)
            }
        }
        .accessibilityHidden(true)
    }
}

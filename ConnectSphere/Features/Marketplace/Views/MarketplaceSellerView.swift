import SwiftUI

/// A seller as the Marketplace shows them — opened by tapping the seller on
/// an item. Like a community member's profile: the profile card, then just
/// their other items; "View full profile" for everything else.
struct MarketplaceSellerView: View {
    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.appBundle) private var bundle
    @Environment(\.colorScheme) private var colorScheme

    @State private var viewModel: MarketplaceSellerViewModel

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
    private var token: String { appState.authToken ?? "" }

    init(seller: UserProfile, mode: AppMode, excluding postId: String) {
        _viewModel = State(initialValue: MarketplaceSellerViewModel(seller: seller, mode: mode, excluding: postId))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: AppSpacing.md) {
                header
                if viewModel.items.isEmpty && !viewModel.isLoading {
                    Text("No other items", bundle: bundle)
                        .font(.system(size: 14))
                        .foregroundColor(AppColors.textTertiary(colorScheme))
                        .padding(.top, 30)
                } else {
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
        .alert(bundle.loc("Error"), isPresented: Binding(get: { viewModel.errorMessage != nil },
                                                          set: { if !$0 { viewModel.errorMessage = nil } })) {
            Button(bundle.loc("OK")) {}
        } message: { Text(viewModel.errorMessage ?? "") }
    }

    /// The same cover and floating card as a community member's profile.
    private var header: some View {
        let seller = viewModel.seller
        return CoverHeader(coverUrl: seller.coverUrl) {
            VStack(spacing: 12) {
                Avatar(name: seller.name, colorHex: seller.avatarColor, imageURL: seller.avatarUrl, diameter: 132)
                    .overlay(Circle().stroke(AppColors.surface(colorScheme), lineWidth: 5))
                    .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
                    .padding(.top, -66)

                VStack(spacing: 4) {
                    Text(seller.name)
                        .font(.system(size: 26, weight: .bold))
                        .foregroundColor(AppColors.textPrimary(colorScheme))
                        .multilineTextAlignment(.center)
                    if !seller.username.isEmpty {
                        Text("@\(seller.username)")
                            .font(.system(size: 15))
                            .foregroundColor(AppColors.textSecondary(colorScheme))
                    }
                    if let location = seller.location, !location.isEmpty {
                        Label(location, systemImage: "mappin.and.ellipse")
                            .font(.system(size: 14))
                            .foregroundColor(AppColors.textSecondary(colorScheme))
                    }
                }

                VStack(spacing: 2) {
                    // The item this page was opened from counts too.
                    Text("\(viewModel.items.count + 1)")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(AppColors.textPrimary(colorScheme))
                    Text("items listed", bundle: bundle)
                        .font(.system(size: 12))
                        .foregroundColor(AppColors.textSecondary(colorScheme))
                }
                .padding(.vertical, 4)
                .accessibilityElement(children: .combine)

                NavigationLink {
                    UserProfileView(userId: seller.id, preloadedUser: seller)
                } label: {
                    Text("View full profile", bundle: bundle)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(themeManager.theme.primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, AppSpacing.sm + 2)
                        .background(themeManager.theme.primary.opacity(0.12),
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
            .padding(.horizontal, AppSpacing.lg)
            .padding(.bottom, AppSpacing.lg)
            .frame(maxWidth: .infinity)
            .background(AppColors.surface(colorScheme),
                        in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .shadow(color: AppElevation.overlay.color(colorScheme), radius: AppElevation.overlay.radius,
                    y: AppElevation.overlay.y)
        }
    }
}

import SwiftUI

/// The Marketplace tab beside Discover: listings from your communities for
/// the mode you're in, the screen's search bar, and a chip per community.
/// "Sell" is the screen's top-right button while this tab is showing.
struct MarketplaceView: View {
    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.appBundle) private var bundle
    @Environment(\.colorScheme) private var colorScheme

    /// Bumped by the Communities screen's top-right "Sell" button.
    @Binding var sellRequest: Int
    @State private var viewModel = MarketplaceViewModel()
    @State private var showSell = false

    private var token: String { appState.authToken ?? "" }
    private var mode: AppMode { appState.currentMode }
    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // The official account sells nothing, so "Yours" would always be empty.
                if !(appState.currentUser?.isOfficial ?? false) { scopeBar }
                chips
                if viewModel.listings.isEmpty && !viewModel.isLoading {
                    empty
                } else {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(viewModel.listings) { post in
                            ListingCard(post: post)
                                .task { if post.id == viewModel.listings.last?.id { await viewModel.loadMore(mode: mode, token: token) } }
                        }
                    }
                    .padding(.horizontal, AppSpacing.lg)
                }
                if viewModel.isLoading { ProgressView().frame(maxWidth: .infinity).padding() }
            }
            .padding(.vertical, 12)
        }
        // The same search bar the other tabs use, searching listings instead.
        .searchable(text: $viewModel.query, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: bundle.loc("Search Marketplace"))
        .onChange(of: viewModel.query) { _, _ in viewModel.searchSoon(mode: mode, token: token) }
        .onChange(of: sellRequest) { _, _ in showSell = true }
        .task { await viewModel.load(mode: mode, token: token) }
        .refreshable { await viewModel.load(mode: mode, token: token) }
        .onChange(of: appState.currentMode) { _, new in
            Task<Void, Never>(name: nil) { await viewModel.pickCommunity(nil, mode: new, token: token) }
        }
        .sheet(isPresented: $showSell) {
            CreateListingView(mode: mode) { viewModel.added($0) }
                .environment(appState)
                .environment(themeManager)
        }
    }

    // MARK: - Scope bar
    /// Top left, small like Messages' Archive button: everyone's items, or just yours.
    private var scopeBar: some View {
        HStack(spacing: AppSpacing.sm) {
            scopeButton(bundle.loc("All"), icon: "square.grid.2x2", selected: !viewModel.mineOnly) {
                await viewModel.setMine(false, mode: mode, userId: appState.currentUser?.id, token: token)
            }
            scopeButton(bundle.loc("Yours"), icon: "person.fill", selected: viewModel.mineOnly) {
                await viewModel.setMine(true, mode: mode, userId: appState.currentUser?.id, token: token)
            }
            Spacer()
        }
        .padding(.horizontal, AppSpacing.lg)
    }

    private func scopeButton(_ title: String, icon: String, selected: Bool, action: @escaping () async -> Void) -> some View {
        Button { Task<Void, Never>(name: nil) { await action() } } label: {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 12, weight: .semibold))
                Text(title).font(.system(size: 13, weight: .semibold))
            }
            .foregroundColor(selected ? .white : AppColors.textSecondary(colorScheme))
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(selected ? themeManager.theme.primary : AppColors.surface(colorScheme), in: Capsule())
            .overlay(Capsule().stroke(selected ? Color.clear : AppColors.borderDefault(colorScheme), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Community chips
    /// A chip per community to narrow the list.
    @ViewBuilder
    private var chips: some View {
        if viewModel.communities.count > 1 {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    chip(bundle.loc("All"), selected: viewModel.communityId == nil) {
                        await viewModel.pickCommunity(nil, mode: mode, token: token)
                    }
                    ForEach(viewModel.communities) { c in
                        chip(c.name, selected: viewModel.communityId == c.id) {
                            await viewModel.pickCommunity(c.id, mode: mode, token: token)
                        }
                    }
                }
                .padding(.horizontal, AppSpacing.lg)
            }
        }
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () async -> Void) -> some View {
        Button { Task<Void, Never>(name: nil) { await action() } } label: {
            Text(title)
                .scaledFont(13, .semibold)
                .lineLimit(1)
                .foregroundColor(selected ? .white : AppColors.textPrimary(colorScheme))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(selected ? themeManager.theme.primary : AppColors.surface(colorScheme), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Empty state
    private var empty: some View {
        VStack(spacing: 10) {
            Image(systemName: "bag")
                .scaledFont(40)
                .foregroundColor(AppColors.textTertiary(colorScheme))
            Text(viewModel.errorMessage ?? bundle.loc("Nothing for sale in your communities yet"))
                .scaledFont(15)
                .foregroundColor(AppColors.textSecondary(colorScheme))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
        .padding(.horizontal, 32)
    }
}

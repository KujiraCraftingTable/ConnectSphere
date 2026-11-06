import SwiftUI

/// "Your items": everything you have for sale in this mode, sold ones last.
/// Open one to edit it, mark it sold or re-up it.
struct MarketplaceMyItemsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.appBundle) private var bundle
    @Environment(\.colorScheme) private var colorScheme
    @Environment(ThemeManager.self) private var themeManager

    @State private var viewModel: MarketplaceMyItemsViewModel
    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    init(mode: AppMode, sellerId: String) {
        _viewModel = State(initialValue: MarketplaceMyItemsViewModel(mode: mode, sellerId: sellerId))
    }

    private var token: String { appState.authToken ?? "" }

    var body: some View {
        ScrollView {
            filterBar
            if viewModel.visibleItems.isEmpty && !viewModel.isLoading {
                VStack(spacing: 10) {
                    Image(systemName: "bag")
                        .font(.system(size: 40))
                        .foregroundColor(AppColors.textTertiary(colorScheme))
                    Text(viewModel.errorMessage ?? bundle.loc("You aren't selling anything yet"))
                        .font(.system(size: 15))
                        .foregroundColor(AppColors.textSecondary(colorScheme))
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 60)
                .padding(.horizontal, 32)
            } else {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(viewModel.visibleItems) { post in
                        ListingCard(post: post)
                            .task { if post.id == viewModel.items.last?.id { await viewModel.loadMore(token: token) } }
                    }
                }
                .padding(.horizontal, AppSpacing.lg)
                .padding(.vertical, 12)
            }
            if viewModel.isLoading { ProgressView().frame(maxWidth: .infinity).padding() }
        }
        .appBackground()
        .navigationTitle(Text("Marketplace", bundle: bundle))
        .navigationBarTitleDisplayMode(.inline)
        .task { await viewModel.load(token: token) }
        .refreshable { await viewModel.load(token: token) }
    }

    /// "All items" / "Available", sold ones hide under Available.
    private var filterBar: some View {
        HStack(spacing: 8) {
            filterChip(bundle.loc("All items"), .all)
            filterChip(bundle.loc("Available"), .available)
            Spacer()
        }
        .padding(.horizontal, AppSpacing.lg)
        .padding(.top, 12)
    }

    private func filterChip(_ title: String, _ value: MarketplaceMyItemsViewModel.Filter) -> some View {
        let selected = viewModel.filter == value
        return Button { viewModel.filter = value } label: {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(selected ? .white : AppColors.textPrimary(colorScheme))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(selected ? themeManager.theme.primary : AppColors.surface(colorScheme), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

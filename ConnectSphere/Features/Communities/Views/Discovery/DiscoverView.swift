import SwiftUI

/// Cross-community discovery: Trending + Recommended sections
struct DiscoverView: View {
    @Environment(AppState.self) var appState
    @Environment(\.colorScheme) var colorScheme
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.appBundle) var bundle
    @State private var viewModel: DiscoverViewModel

    /// Called when user taps a community card — navigates to detail
    let onSelectCommunity: (String) -> Void

    init(token: String, onSelectCommunity: @escaping (String) -> Void) {
        _viewModel           = State(initialValue: DiscoverViewModel(token: token))
        self.onSelectCommunity = onSelectCommunity
    }

    private var modeType: CommunityType { appState.currentMode == .hobby ? .fandom : .work }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                if viewModel.isLoading {
                    skeletonLoader
                } else {
                    // Trending section
                    if !viewModel.trending.isEmpty {
                        TrendingSection(communities: viewModel.trending) { community in
                            onSelectCommunity(community.id)
                        }
                    }

                    // Recommended section
                    RecommendedSection(communities: viewModel.recommended) { community in
                        onSelectCommunity(community.id)
                    }

                    if viewModel.trending.isEmpty && viewModel.recommended.isEmpty {
                        emptyState
                    }
                }
            }
            .padding(.vertical, 16)
        }
        .appBackground()
        .task { await viewModel.fetchDiscover(type: modeType) }
        .refreshable { await viewModel.fetchDiscover(type: modeType) }
        .onChange(of: appState.currentMode) { _, _ in
            Task<Void, Never>(name: nil) { await viewModel.fetchDiscover(type: modeType) }
        }
        .alert(bundle.loc("Error"), isPresented: .constant(viewModel.errorMessage != nil)) {
            Button(bundle.loc("OK")) { viewModel.errorMessage = nil }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
    }

    // MARK: - Skeleton loading

    private var skeletonLoader: some View {
        VStack(alignment: .leading, spacing: 24) {
            skeletonSection(count: 4)
            skeletonSection(count: 3)
        }
    }

    private func skeletonSection(count: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            RoundedRectangle(cornerRadius: 6)
                .fill(AppColors.elevated(colorScheme))
                .frame(width: 140, height: 18)
                .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(0..<count, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 12)
                            .fill(AppColors.elevated(colorScheme))
                            .frame(width: 80, height: 100)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
        .redacted(reason: .placeholder)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 40))
                .foregroundColor(AppColors.textTertiary(colorScheme))
            Text("Nothing to discover yet", bundle: bundle)
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(AppColors.textSecondary(colorScheme))
            Text("Come back when there are more communities", bundle: bundle)
                .font(.system(size: 14))
                .foregroundColor(AppColors.textTertiary(colorScheme))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }
}

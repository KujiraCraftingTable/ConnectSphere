import SwiftUI

/// Cross-community discovery: Trending + Recommended sections
struct DiscoverView: View {
    @Environment(AppState.self) var appState
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.appBundle) var bundle
    @State private var viewModel: DiscoverViewModel
    @State private var selectedType: CommunityType? = nil

    /// Called when user taps a community card — navigates to detail
    let onSelectCommunity: (String) -> Void

    init(token: String, onSelectCommunity: @escaping (String) -> Void) {
        _viewModel           = State(initialValue: DiscoverViewModel(token: token))
        self.onSelectCommunity = onSelectCommunity
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                // Category filter chips
                categoryChips
                    .padding(.horizontal, 16)

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
        .task { await viewModel.fetchDiscover(type: selectedType) }
        .refreshable { await viewModel.fetchDiscover(type: selectedType) }
        .alert(bundle.loc("Lỗi"), isPresented: .constant(viewModel.errorMessage != nil)) {
            Button(bundle.loc("OK")) { viewModel.errorMessage = nil }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
    }

    // MARK: - Category chips

    private var categoryChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                filterChip(label: bundle.loc("Tất cả"), type: nil)
                ForEach(CommunityType.allCases, id: \.self) { t in
                    filterChip(label: t.label, type: t)
                }
            }
        }
    }

    private func filterChip(label: String, type: CommunityType?) -> some View {
        let isSelected = selectedType == type
        return Button {
            selectedType = type
            Task<Void, Never>(name: nil) { await viewModel.fetchDiscover(type: type) }
        } label: {
            Text(label)
                .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                .foregroundColor(isSelected ? .white : AppColors.textSecondary(colorScheme))
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(isSelected ? Color.purple : AppColors.elevated(colorScheme))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
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
            Text("Chưa có gì để khám phá", bundle: bundle)
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(AppColors.textSecondary(colorScheme))
            Text("Hãy quay lại sau khi có thêm cộng đồng mới", bundle: bundle)
                .font(.system(size: 14))
                .foregroundColor(AppColors.textTertiary(colorScheme))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }
}

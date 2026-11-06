import SwiftUI

/// Cross-community discovery: Trending + Recommended sections
struct DiscoverView: View {
    @Environment(AppState.self) var appState
    @Environment(\.colorScheme) var colorScheme
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.appBundle) var bundle
    @State private var viewModel: DiscoverViewModel
    @State private var searchText = ""
    @State private var searchTask: Task<Void, Never>?

    /// Called when user taps a community card. Navigates to detail
    let onSelectCommunity: (String) -> Void

    init(token: String, onSelectCommunity: @escaping (String) -> Void) {
        _viewModel           = State(initialValue: DiscoverViewModel(token: token))
        self.onSelectCommunity = onSelectCommunity
    }

    private var modeType: CommunityType { appState.currentMode == .hobby ? .fandom : .work }
    private var isSearchActive: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                if isSearchActive {
                    searchResultsSection
                } else if viewModel.isLoading {
                    skeletonLoader
                } else {
                    if !viewModel.trending.isEmpty {
                        CommunityListSection(title: bundle.loc("Trending Now"), icon: "flame.fill",
                                             communities: viewModel.trending,
                                             onTap: { onSelectCommunity($0.id) },
                                             onToggle: toggle)
                    }
                    CommunityListSection(title: bundle.loc("Recommended For You"), icon: "sparkles",
                                         communities: viewModel.recommended,
                                         emptyText: bundle.loc("Join some communities to get personalised recommendations"),
                                         onTap: { onSelectCommunity($0.id) },
                                         onToggle: toggle)

                    if viewModel.trending.isEmpty && viewModel.recommended.isEmpty {
                        emptyState
                    }
                }
            }
            .padding(.vertical, 16)
        }
        .appBackground()
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: bundle.loc("Search communities"))
        .onChange(of: searchText) { _, newValue in
            searchTask?.cancel()
            let trimmed = newValue.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return }
            searchTask = Task {
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard !Task.isCancelled else { return }
                await viewModel.search(query: trimmed, type: modeType)
            }
        }
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

    @ViewBuilder
    private var searchResultsSection: some View {
        if viewModel.isSearching && viewModel.searchResults.isEmpty {
            ProgressView().padding(.top, 40).frame(maxWidth: .infinity)
        } else if viewModel.searchResults.isEmpty {
            Text(bundle.loc("No results found"))
                .scaledFont(14)
                .foregroundColor(AppColors.textTertiary(colorScheme))
                .padding(.horizontal, 16)
        } else {
            ForEach(viewModel.searchResults) { community in
                Button { onSelectCommunity(community.id) } label: {
                    CommunityRow(community: community) { toggle(community) }
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
            }
        }
    }

    private func toggle(_ community: Community) {
        Task<Void, Never>(name: nil) { await viewModel.toggleMembership(community) }
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

            ForEach(0..<count, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 16)
                    .fill(AppColors.elevated(colorScheme))
                    .frame(height: 88)
                    .padding(.horizontal, 16)
            }
        }
        .redacted(reason: .placeholder)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .scaledFont(40)
                .foregroundColor(AppColors.textTertiary(colorScheme))
            Text("Nothing to discover yet", bundle: bundle)
                .scaledFont(16, .medium)
                .foregroundColor(AppColors.textSecondary(colorScheme))
            Text("Come back when there are more communities", bundle: bundle)
                .scaledFont(14)
                .foregroundColor(AppColors.textTertiary(colorScheme))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }
}

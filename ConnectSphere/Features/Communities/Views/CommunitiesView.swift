import SwiftUI

// Tabs for the Communities top-level screen
private enum CommunityTab: CaseIterable {
    case myCommunities, discover, marketplace
    var label: String {
        switch self {
        case .myCommunities: return "My communities"
        case .discover:      return "Discover"
        case .marketplace:   return "Marketplace"
        }
    }
}

struct CommunitiesView: View {
    @Environment(AppState.self) var appState
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.appBundle) var bundle

    @State private var viewModel  = CommunitiesViewModel()
    @State private var selectedTab: CommunityTab = .myCommunities
    @State private var searchText = ""
    @State private var showCreate = false
    /// The top-right "Sell" on the Marketplace tab; MarketplaceView reacts to each bump.
    @State private var sellRequest = 0

    /// Binding from MainTabView. Resets to root whenever the tab is re-selected
    @Binding var navPath: NavigationPath

    var body: some View {
        NavigationStack(path: $navPath) {
            VStack(spacing: 0) {
                // The same search box as the Search tab (My communities only).
                if selectedTab == .myCommunities {
                    SearchPillField(text: $searchText, placeholder: bundle.loc("Search communities"))
                        .padding(.horizontal, 16)
                        .padding(.top, 4)
                        .background(AppColors.surface(colorScheme))
                }

                // Tab picker, pinned below navigation bar
                Picker("", selection: $selectedTab) {
                    ForEach(CommunityTab.allCases, id: \.self) { tab in
                        Text(bundle.loc(tab.label)).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(AppColors.surface(colorScheme))

                Divider()

                // Tab content
                switch selectedTab {
                case .myCommunities:
                    myCommunitiesContent
                case .discover:
                    DiscoverView(token: appState.authToken ?? "") { communityId in
                        navPath.append(communityId)
                    }
                case .marketplace:
                    MarketplaceView(sellRequest: $sellRequest)
                }
            }
            .appBackground()
            .navigationTitle(bundle.loc(selectedTab == .marketplace ? "Marketplace" : "Community"))
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    if selectedTab == .marketplace {
                        // The official account only monitors the Marketplace: no Sell.
                        if !(appState.currentUser?.isOfficial ?? false) {
                        // Icon and word spelled out: the toolbar shows a Label as its icon alone.
                        Button { sellRequest += 1 } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "plus")
                                Text(bundle.loc("Sell"))
                            }
                            .scaledFont(15, .semibold)
                            .foregroundColor(themeManager.theme.primary)
                            .padding(.horizontal, 6)
                        }
                        .disabledWhenRestricted()
                        }
                    } else if !(appState.currentUser?.isOfficial ?? false) {
                        // Creating a community would make the official account its member.
                        Button { showCreate = true } label: {
                            // Plain glyph, a filled disc read as a button inside the glass.
                            Image(systemName: "plus")
                                .scaledFont(17, .semibold)
                                .foregroundColor(themeManager.theme.primary)
                        }
                        .accessibilityLabel(Bundle.app.loc("Create community"))
                        .disabledWhenRestricted()
                    }
                }
            }
            .task {
                await viewModel.fetchInitial(token: appState.authToken ?? "",
                                             type: .fandom)
            }
            // Tab re-tapped: reload the lists.
            .onChange(of: appState.communitiesReloadTick) {
                // Back to My communities from Marketplace or Discover.
                withAnimation { selectedTab = .myCommunities }
                Task { await viewModel.fetchInitial(token: appState.authToken ?? "",
                                                    type: .fandom) }
            }
            // Joined, left, pinned or edited elsewhere: refresh the list.
            .onReceive(NotificationCenter.default.publisher(for: .communitiesChanged)) { _ in
                Task { await viewModel.loadMyCommunities() }
            }
            .sheet(isPresented: $showCreate) {
                CreateCommunityView(
                    existingCommunities: viewModel.myCommunities + viewModel.discoverCommunities
                ) { newCommunity in
                    viewModel.myCommunities.insert(newCommunity, at: 0)
                }
                .environment(appState)
                .environment(themeManager)
            }
            .navigationDestination(for: String.self) { communityId in
                CommunityDetailView(
                    communityId: communityId, token: appState.authToken ?? "",
                    currentUserId: appState.currentUser?.id ?? ""
                )
                    .environment(appState)
            }
            .alert(bundle.loc("Error"), isPresented: .constant(viewModel.errorMessage != nil)) {
                Button(bundle.loc("OK")) { viewModel.errorMessage = nil }
            } message: {
                Text(viewModel.errorMessage ?? "")
            }
        }
    }

    // MARK: - My Communities tab

    private var myCommunitiesContent: some View {
        ScrollView {
            // Same spacing token used for every gap. Between cards AND
            // before the first one, so the list reads evenly throughout.
            LazyVStack(alignment: .leading, spacing: AppSpacing.sm) {
                if viewModel.isLoadingMine && viewModel.myCommunities.isEmpty {
                    ProgressView()
                        .padding(.top, 60)
                        .frame(maxWidth: .infinity)
                } else if let myError = viewModel.myError, viewModel.myCommunities.isEmpty {
                    myCommunitiesError(myError)
                } else {
                    typeSection(.fandom)
                }
            }
            .padding(.top, AppSpacing.sm)
            .padding(.bottom, 20)
        }
    }

    private func myCommunitiesError(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark")
                .scaledFont(36)
                .foregroundColor(AppColors.textTertiary(colorScheme))
            Text(message)
                .scaledFont(14)
                .multilineTextAlignment(.center)
                .foregroundColor(AppColors.textSecondary(colorScheme))
                .padding(.horizontal, 32)
            Button(bundle.loc("Retry")) {
                Task<Void, Never>(name: nil) { await viewModel.loadMyCommunities() }
            }
            .scaledFont(14, .semibold)
            .foregroundColor(themeManager.theme.primary)
        }
        .padding(.top, 60)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func typeSection(_ type: CommunityType) -> some View {
        let all = viewModel.myCommunities.filter { $0.type == type }
        let visible = searchText.isEmpty
            ? all
            : all.filter { $0.name.localizedCaseInsensitiveContains(searchText) }

        if visible.isEmpty {
            Text(searchText.isEmpty ? bundle.loc("You haven't joined any communities") : bundle.loc("No results found"))
                .scaledFont(14)
                .foregroundColor(AppColors.textTertiary(colorScheme))
                .padding(.horizontal, 16)
                .padding(.top, 2)
        } else {
            ForEach(visible) { community in
                NavigationLink(value: community.id) {
                    CommunityRow(community: community) {
                        Task<Void, Never>(name: nil) { await viewModel.leave(community) }
                    }
                    .padding(.horizontal, 16)
                }
                .buttonStyle(.plain)
            }
        }
    }

}

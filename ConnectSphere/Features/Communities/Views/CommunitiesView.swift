import SwiftUI

// Tabs for the Communities top-level screen
private enum CommunityTab: CaseIterable {
    case myCommunities, discover
    var label: String {
        switch self {
        case .myCommunities: return "My communities"
        case .discover:      return "Discover"
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
    /// Icon-triggered search — collapsed by default, tapping the magnifying
    /// glass in the toolbar swaps the segmented tab picker row for a
    /// focused text field. Shared between both tabs (`myCommunitiesContent`
    /// filters client-side, `DiscoverView` searches server-side) since they
    /// sit on this one shared toolbar.
    @State private var showSearchField = false
    @FocusState private var isSearchFieldFocused: Bool

    /// Binding from MainTabView — resets to root whenever the tab is re-selected
    @Binding var navPath: NavigationPath

    var body: some View {
        NavigationStack(path: $navPath) {
            VStack(spacing: 0) {
                // Tab picker — pinned below navigation bar. While searching,
                // this row becomes the search field instead (there's no
                // meaningful "which tab" while actively searching across
                // either tab's content).
                if showSearchField {
                    searchFieldRow
                } else {
                    Picker("", selection: $selectedTab) {
                        ForEach(CommunityTab.allCases, id: \.self) { tab in
                            Text(bundle.loc(tab.label)).tag(tab)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(AppColors.surface(colorScheme))
                }

                Divider()

                // Tab content
                switch selectedTab {
                case .myCommunities:
                    myCommunitiesContent
                case .discover:
                    DiscoverView(token: appState.authToken ?? "", searchText: $searchText) { communityId in
                        navPath.append(communityId)
                    }
                }
            }
            .appBackground()
            .navigationTitle(bundle.loc("Community"))
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showCreate = true } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 20))
                            .foregroundColor(themeManager.theme.primary)
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showSearchField = true
                        isSearchFieldFocused = true
                    } label: {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 20))
                            .foregroundColor(themeManager.theme.primary)
                    }
                }
            }
            .task {
                await viewModel.fetchInitial(token: appState.authToken ?? "")
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
            // Same spacing token used for every gap — between cards AND
            // before the first one — so the list reads evenly throughout.
            LazyVStack(alignment: .leading, spacing: AppSpacing.sm) {
                if viewModel.isLoadingMine && viewModel.myCommunities.isEmpty {
                    ProgressView()
                        .padding(.top, 60)
                        .frame(maxWidth: .infinity)
                } else if let myError = viewModel.myError, viewModel.myCommunities.isEmpty {
                    myCommunitiesError(myError)
                } else {
                    typeSection(appState.currentMode == .hobby ? .fandom : .work)
                }
            }
            .padding(.top, AppSpacing.sm)
            .padding(.bottom, 20)
        }
    }

    /// Replaces the tab picker row while `showSearchField` is true —
    /// focused text field + Cancel, driving whichever tab is active
    /// (`searchText` is shared with `DiscoverView` via binding).
    private var searchFieldRow: some View {
        HStack(spacing: 10) {
            TextField("", text: $searchText, prompt: Text(bundle.loc("Search communities")))
                .focused($isSearchFieldFocused)
                .font(.system(size: 15))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(AppColors.elevated(colorScheme), in: RoundedRectangle(cornerRadius: 20))
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(AppColors.borderStrong(colorScheme), lineWidth: 1)
                )

            Button(bundle.loc("Cancel")) {
                searchText = ""
                showSearchField = false
                isSearchFieldFocused = false
            }
            .font(.system(size: 15, weight: .medium))
            .foregroundColor(themeManager.theme.primary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(AppColors.surface(colorScheme))
    }

    private func myCommunitiesError(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 36))
                .foregroundColor(AppColors.textTertiary(colorScheme))
            Text(message)
                .font(.system(size: 14))
                .multilineTextAlignment(.center)
                .foregroundColor(AppColors.textSecondary(colorScheme))
                .padding(.horizontal, 32)
            Button(bundle.loc("Retry")) {
                Task<Void, Never>(name: nil) { await viewModel.loadMyCommunities() }
            }
            .font(.system(size: 14, weight: .semibold))
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
                .font(.system(size: 14))
                .foregroundColor(AppColors.textTertiary(colorScheme))
                .padding(.horizontal, 16)
                .padding(.top, 2)
        } else {
            ForEach(visible) { community in
                NavigationLink(value: community.id) {
                    CommunityCard(community: community) {
                        Task<Void, Never>(name: nil) { await viewModel.leave(community) }
                    }
                    .padding(.horizontal, 16)
                }
                .buttonStyle(.plain)
            }
        }
    }

}

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

    /// Binding from MainTabView — resets to root whenever the tab is re-selected
    @Binding var navPath: NavigationPath

    var body: some View {
        NavigationStack(path: $navPath) {
            VStack(spacing: 0) {
                // Tab picker — pinned below navigation bar
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
            LazyVStack(alignment: .leading, spacing: 16) {
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
            .padding(.bottom, 20)
        }
        .searchable(text: $searchText, prompt: bundle.loc("Search communities"))
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

        typeSectionHeader(bundle.loc(type.label), count: all.count)

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

    // MARK: - Helpers

    private func typeSectionHeader(_ title: String, count: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(AppColors.textPrimary(colorScheme))
            Text("\(count)")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(AppColors.textSecondary(colorScheme))
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
    }

}

import SwiftUI

// Tabs for the Communities top-level screen
private enum CommunityTab: CaseIterable {
    case myCommunities, discover
    var label: String {
        switch self {
        case .myCommunities: return "Cộng đồng của tôi"
        case .discover:      return "Khám phá"
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
    @State private var selectedType: CommunityType? = nil
    @State private var showCreate = false

    var body: some View {
        NavigationStack {
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
                        _ = communityId
                    }
                }
            }
            .appBackground()
            .navigationTitle(bundle.loc("Cộng đồng"))
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
            .task { await viewModel.fetchInitial(token: appState.authToken ?? "") }
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
                CommunityDetailView(communityId: communityId, token: appState.authToken ?? "")
                    .environment(appState)
            }
            .alert(bundle.loc("Lỗi"), isPresented: .constant(viewModel.errorMessage != nil)) {
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
                filterChips.padding(.horizontal, 16).padding(.top, 5)

                switch selectedType {
                case nil:
                    typeSection(.fandom)
                    typeSection(.work)
                case .fandom:
                    typeSection(.fandom)
                case .work:
                    typeSection(.work)
                }
            }
            .padding(.bottom, 20)
        }
        .searchable(text: $searchText, prompt: bundle.loc("Tìm cộng đồng"))
    }

    @ViewBuilder
    private func typeSection(_ type: CommunityType) -> some View {
        let all = viewModel.myCommunities.filter { $0.type == type }
        let visible = searchText.isEmpty
            ? all
            : all.filter { $0.name.localizedCaseInsensitiveContains(searchText) }

        typeSectionHeader(type.label, count: all.count)

        if visible.isEmpty {
            Text(searchText.isEmpty ? bundle.loc("Chưa tham gia cộng đồng nào") : bundle.loc("Không tìm thấy kết quả"))
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

    // MARK: - Filter chips

    private var filterChips: some View {
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
        } label: {
            Text(label)
                .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                .foregroundColor(isSelected ? .white : AppColors.textSecondary(colorScheme))
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(isSelected ? themeManager.theme.primary : AppColors.elevated(colorScheme))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
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

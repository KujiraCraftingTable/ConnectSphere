import SwiftUI

struct CommunityDetailView: View {
    @Environment(AppState.self) var appState
    @Environment(\.colorScheme) var colorScheme
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.appBundle) var bundle
    @State private var viewModel: CommunityDetailViewModel
    @State private var showCreatePost = false
    @State private var showJoinRequests  = false
    @State private var showModeration    = false
    @State private var showAnalytics     = false
    @State private var showSettings      = false
    @State private var showEdit          = false
    @State private var showReportCommunity = false
    @State private var showInfo          = false
    @State private var showMyContent     = false
    @State private var showPendingPosts  = false
    @State private var showNotifications = false
    @State private var showShare         = false
    @State private var showMyProfile     = false
    /// Search field under the header, opened by the toolbar's magnifier.
    @State private var showSearch        = false
    /// Scrolling down hides the search field, Feed/Members and the tab bar.
    @State private var barsHidden        = false
    /// Status bar + navigation bar: the cover runs up under both.
    @State private var topInset: CGFloat = 0
    @State private var pull: CGFloat = 0
    @Environment(\.dismiss) private var dismiss
    // Tap-to-open-post-detail — same PostRoute/PostDetailView navigation Feed uses.
    @State private var detailRoute: PostRoute?
    /// What's looked at here, for ranking feeds.
    @State private var impressions = ImpressionTracker(source: .community)
    @Environment(\.scenePhase) private var scenePhase
    @State private var searchText = ""
    @State private var searchTask: Task<Void, Never>?

    private var isSearchActive: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    let communityId: String

    init(communityId: String, token: String, currentUserId: String) {
        self.communityId = communityId
        _viewModel = State(initialValue: CommunityDetailViewModel(
            communityId: communityId, token: token, currentUserId: currentUserId
        ))
    }

    // MARK: - Computed helpers

    private var accentColor: Color { themeManager.theme.primary }

    private var currentUserRole: MemberRole? {
        viewModel.community?.role
    }

    private var isStaff: Bool {
        currentUserRole == .admin || currentUserRole == .moderator
    }

    /// A private community the viewer hasn't joined — the posts and members
    /// endpoints are 403-gated server-side, so show a "request to join" prompt
    /// rather than the misleading "No posts yet" / empty roster.
    private var isPrivateLockedOut: Bool {
        viewModel.community?.privacy == .private && viewModel.community?.isMember == false
    }

    // MARK: - Body

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                // Pulled up under the bars rather than ignoring the safe area
                // on the scroll view, so Feed/Members still pins below them.
                communityHeader
                    .padding(.top, -topInset)

                Section(header: stickyBar) {
                    feedContent
                }
            }
        }
        .hidesBarsOnScroll($barsHidden)
        // Back, search and "..." slide away with the tab bar while reading down.
        .toolbar(barsHidden ? .hidden : .visible, for: .navigationBar)
        .trackPull($pull)
        // Measured with the bars showing only: hiding them shrinks the inset,
        // and the header (long scrolled past by then) shouldn't move.
        .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.top } action: { if !barsHidden { topInset = $0 } }
        .appBackground()
        .navigationBarTitleDisplayMode(.inline)
        // Back, search and "..." float on the cover.
        .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
        .hidesTopScrollEdgeEffect()
        .toolbar {
            // Like Facebook: search, then "..." — no share icon.
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    withAnimation(.snappy) { showSearch.toggle() }
                    if !showSearch { searchText = "" }
                } label: {
                    Image(systemName: "magnifyingglass").font(.system(size: 17))
                }
                .accessibilityLabel(Text("Search this community", bundle: bundle))
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu { moreMenu } label: {
                    Image(systemName: "ellipsis").font(.system(size: 17))
                }
                .accessibilityLabel(Text("More", bundle: bundle))
            }
        }
        .onChange(of: searchText) { _, newValue in
            searchTask?.cancel()
            let trimmed = newValue.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return }
            searchTask = Task {
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard !Task.isCancelled else { return }
                await viewModel.searchPosts(query: trimmed)
            }
        }
        .task { await viewModel.fetchAll() }
        .refreshable { await viewModel.refresh() }
        .overlay(alignment: .top) { PullRefreshIndicator(pull: pull, isRefreshing: viewModel.isRefreshing) }
        .onAppear { viewModel.joinCommunityRoom() }
        .onDisappear {
            viewModel.leaveCommunityRoom()
            impressions.pause()
        }
        .onChange(of: scenePhase) { _, phase in if phase != .active { impressions.pause() } }
        .overlay(alignment: .bottomTrailing) {
            if viewModel.community?.isMember == true {
                createPostFAB
            }
        }
        .sheet(isPresented: $showCreatePost) {
            if let community = viewModel.community {
                CreatePostView(community: community, onPostCreated: { post in
                    viewModel.prependPost(post)
                })
                .environment(appState)
                .environment(themeManager)
            }
        }
        .sheet(isPresented: $showShare) {
            if let community = viewModel.community {
                ShareCommunitySheet(community: community)
            }
        }
        .sheet(isPresented: $showMyProfile) {
            ProfilePopup { CommunityMemberProfileView(communityId: communityId, userId: appState.currentUser?.id ?? "") }
        }
        .sheet(isPresented: $showNotifications) {
            CommunityNotificationsSheet(viewModel: viewModel)
        }
        .sheet(isPresented: $showSettings) {
            CommunitySettingsSheet(viewModel: viewModel) { dismiss() }
        }
        .sheet(isPresented: $showEdit) {
            if let community = viewModel.community {
                EditCommunityView(community: community) { viewModel.applyEdited($0) }
            }
        }
        .sheet(isPresented: $showReportCommunity) {
            ReportSheet(targetType: "community", targetId: communityId,
                        communityId: communityId, token: appState.authToken ?? "")
        }
        .navigationDestination(isPresented: $showMyContent) {
            ManageCommunityContentView(communityId: communityId)
        }
        .navigationDestination(isPresented: $showPendingPosts) {
            PendingPostsView(communityId: communityId)
        }
        .alert(bundle.loc("Your post is waiting for approval"), isPresented: $viewModel.awaitingApprovalNotice) {
            Button(bundle.loc("OK")) {}
        } message: {
            Text("An admin or moderator will review it. You'll find it in \"...\" › Manage your content.", bundle: bundle)
        }
        .navigationDestination(isPresented: $showInfo) {
            if let community = viewModel.community {
                CommunityInfoView(community: community, roster: viewModel.members) {
                    CommunityMembersView(viewModel: viewModel)
                }
            }
        }
        .navigationDestination(isPresented: Binding(
            get: { detailRoute != nil },
            set: { if !$0 { detailRoute = nil } }
        )) {
            if let route = detailRoute {
                PostDetailView(postId: route.postId, focusComposer: route.focusComposer)
            }
        }
        .navigationDestination(isPresented: $showJoinRequests) {
            JoinRequestsView(
                communityId: viewModel.community?.id ?? "",
                token: appState.authToken ?? ""
            )
        }
        .navigationDestination(isPresented: $showModeration) {
            ModerationQueueView(
                communityId: viewModel.community?.id ?? "",
                token:       appState.authToken ?? "",
                coverColor:  viewModel.community?.coverColor ?? "#7F5AF0"
            )
        }
        .navigationDestination(isPresented: $showAnalytics) {
            CommunityAnalyticsView(
                communityId: viewModel.community?.id ?? "",
                token:       appState.authToken ?? "",
                coverColor:  viewModel.community?.coverColor ?? "#7F5AF0"
            )
        }
        .alert(bundle.loc("Error"), isPresented: .constant(viewModel.errorMessage != nil)) {
            Button(bundle.loc("OK")) { viewModel.errorMessage = nil }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
    }

    // MARK: - "..." menu

    @ViewBuilder
    private var moreMenu: some View {
        if viewModel.community?.isMember == true {
            Button { showMyContent = true } label: {
                Label(bundle.loc("Manage your content"), systemImage: "doc.text.magnifyingglass")
            }
            Button { showShare = true } label: {
                Label(bundle.loc("Share community"), systemImage: "arrowshape.turn.up.right")
            }
            Button { showMyProfile = true } label: {
                Label(bundle.loc("Your community profile"), systemImage: "person.crop.square")
            }
            Button { showNotifications = true } label: {
                Label(bundle.loc("Manage notifications"), systemImage: "bell")
            }
            Button { showSettings = true } label: {
                Label(bundle.loc("Community settings"), systemImage: "gearshape")
            }
            if isStaff {
                Section {
                    Button { showEdit = true } label: {
                        Label(bundle.loc("Edit community"), systemImage: "pencil")
                    }
                    Button { showPendingPosts = true } label: {
                        Label(bundle.loc("Pending posts"), systemImage: "hourglass")
                    }
                    Button { showModeration = true } label: {
                        Label(bundle.loc("Moderation"), systemImage: "shield.lefthalf.filled")
                    }
                    if viewModel.community?.privacy == .private {
                        Button { showJoinRequests = true } label: {
                            Label(bundle.loc("Join requests"), systemImage: "person.badge.plus")
                        }
                    }
                    if currentUserRole == .admin {
                        Button { showAnalytics = true } label: {
                            Label(bundle.loc("Analytics"), systemImage: "chart.xyaxis.line")
                        }
                    }
                }
            }
        } else {
            Button { showShare = true } label: {
                Label(bundle.loc("Share community"), systemImage: "arrowshape.turn.up.right")
            }
            Button { showReportCommunity = true } label: {
                Label(bundle.loc("Report community"), systemImage: "flag")
            }
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var communityHeader: some View {
        if let community = viewModel.community {
            CommunityHeaderCard(community: community, topInset: topInset, onInfo: { showInfo = true }) {
                if !community.isMember {
                    joinButton.padding(.top, 6)
                }
            }
        } else {
            AppColors.surface(colorScheme)
                .frame(height: topInset + CommunityHeaderCard<EmptyView>.visibleCoverHeight)
        }
    }

    /// The search field, when open — pinned under the nav bar, and out of the
    /// way while scrolling down the posts.
    private var stickyBar: some View {
        VStack(spacing: 0) {
            if showSearch {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundColor(AppColors.textSecondary(colorScheme))
                    TextField(bundle.loc("Search posts"), text: $searchText)
                        .textInputAutocapitalization(.never)
                        .submitLabel(.search)
                    if !searchText.isEmpty {
                        Button { searchText = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundColor(AppColors.textTertiary(colorScheme))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(AppColors.elevated(colorScheme), in: Capsule())
                .padding(.horizontal, AppSpacing.md)
                .padding(.vertical, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .background(AppColors.surface(colorScheme))
        // Slides up behind the nav bar instead of collapsing, so the posts
        // underneath don't jump.
        .offset(y: barsHidden ? -120 : 0)
        .opacity(barsHidden ? 0 : 1)
        .allowsHitTesting(!barsHidden)
    }

    @ViewBuilder
    private var joinButton: some View {
        switch viewModel.joinStatus {
        case .notMember:
            Button {
                Task<Void, Never>(name: nil) { await viewModel.requestToJoin() }
            } label: {
                joinButtonLabel(
                    title: viewModel.community?.privacy == .private ? bundle.loc("Request to join") : bundle.loc("Join"),
                    bg: themeManager.theme.primary, fg: .white
                )
            }
            .buttonStyle(.plain)

        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.vertical, AppSpacing.sm + 2)

        case .pending:
            joinButtonLabel(title: bundle.loc("Pending"),
                            bg: AppColors.elevated(colorScheme),
                            fg: AppColors.textSecondary(colorScheme))
                .disabled(true)

        case .joined:
            EmptyView()
        }
    }

    private func joinButtonLabel(title: String, bg: Color, fg: Color) -> some View {
        Text(title)
            .appFont(.subheadline)
            .fontWeight(.semibold)
            .foregroundColor(fg)
            .frame(maxWidth: .infinity)     // spans the header card
            .padding(.vertical, AppSpacing.sm + 2)
            .background(bg)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - Feed

    @ViewBuilder
    private var feedContent: some View {
        if isPrivateLockedOut {
            privateLockedNotice(bundle.loc("This community is private. Request to join to see its posts."))
        } else if isSearchActive {
            searchResultsSection
        } else if viewModel.isLoadingPosts && viewModel.posts.isEmpty {
            ProgressView()
                .padding(.top, 40)
                .frame(maxWidth: .infinity)
        } else if viewModel.posts.isEmpty {
            emptyFeed
        } else {
            LazyVStack(spacing: AppSpacing.sm) {
                ForEach(viewModel.posts) { post in
                    PostCard(
                        post: post,
                        onPostDeleted: { viewModel.removePost(id: post.id) },
                        onPostUpdated: { updated in
                            if let idx = viewModel.posts.firstIndex(where: { $0.id == updated.id }) {
                                viewModel.posts[idx] = updated
                            }
                        },
                        onOpenDetail: { focus in
                            impressions.opened(post.id)
                            detailRoute = PostRoute(postId: post.id, focusComposer: focus)
                        },
                        onPin: isStaff ? {
                            Task<Void, Never>(name: nil) { await viewModel.pinPost(post.id) }
                        } : nil,
                        onUnpin: isStaff ? {
                            Task<Void, Never>(name: nil) { await viewModel.unpinPost(post.id) }
                        } : nil,
                        insideCommunityId: communityId
                    )
                    .cardStyle()
                    .tracksImpression(post.id, in: impressions)
                    .task { await viewModel.loadMorePostsIfNeeded(currentPost: post) }
                }
                if viewModel.isLoadingPosts {
                    ProgressView().padding(.vertical, 12)
                }
            }
            .padding(.horizontal, AppSpacing.sm)
            .padding(.top, 8)
            .padding(.bottom, 80)
        }
    }

    @ViewBuilder
    private var searchResultsSection: some View {
        if viewModel.isSearchingPosts && viewModel.searchResults.isEmpty {
            ProgressView().padding(.top, 40).frame(maxWidth: .infinity)
        } else if viewModel.searchResults.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 36))
                    .foregroundColor(AppColors.textTertiary(colorScheme))
                Text("No results found", bundle: bundle)
                    .font(.system(size: 14))
                    .foregroundColor(AppColors.textSecondary(colorScheme))
            }
            .padding(.top, 40)
            .frame(maxWidth: .infinity)
        } else {
            LazyVStack(spacing: AppSpacing.sm) {
                ForEach(viewModel.searchResults) { post in
                    PostCard(
                        post: post,
                        onPostDeleted: { viewModel.searchResults.removeAll { $0.id == post.id } },
                        onOpenDetail: { focus in
                            impressions.opened(post.id)
                            detailRoute = PostRoute(postId: post.id, focusComposer: focus)
                        },
                        onPin: isStaff ? {
                            Task<Void, Never>(name: nil) { await viewModel.pinPost(post.id) }
                        } : nil,
                        onUnpin: isStaff ? {
                            Task<Void, Never>(name: nil) { await viewModel.unpinPost(post.id) }
                        } : nil,
                        insideCommunityId: communityId
                    )
                    .cardStyle()
                    .tracksImpression(post.id, in: impressions)
                }
            }
            .padding(.horizontal, AppSpacing.sm)
            .padding(.top, 8)
            .padding(.bottom, 80)
        }
    }

    private var emptyFeed: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.text")
                .font(.system(size: 40))
                .foregroundColor(AppColors.textTertiary(colorScheme))
            Text("No posts yet", bundle: bundle)
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(AppColors.textSecondary(colorScheme))
            if viewModel.community?.isMember == true {
                Text("Be the first to post in this community!", bundle: bundle)
                    .font(.system(size: 14))
                    .foregroundColor(AppColors.textTertiary(colorScheme))
            }
        }
        .padding(.top, 60)
        .frame(maxWidth: .infinity)
    }

    private func privateLockedNotice(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.fill")
                .font(.system(size: 40))
                .foregroundColor(AppColors.textTertiary(colorScheme))
            Text(message)
                .font(.system(size: 15))
                .multilineTextAlignment(.center)
                .foregroundColor(AppColors.textSecondary(colorScheme))
                .padding(.horizontal, 32)
        }
        .padding(.top, 60)
        .frame(maxWidth: .infinity)
    }

    // MARK: - FAB

    private var createPostFAB: some View {
        Button { showCreatePost = true } label: {
            Image(systemName: "plus")
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 54, height: 54)
                .background(accentColor)
                .clipShape(Circle())
                .shadow(color: accentColor.opacity(0.5), radius: 8, x: 0, y: 4)
        }
        .padding(.trailing, 20)
        .padding(.bottom, 24)
    }
}

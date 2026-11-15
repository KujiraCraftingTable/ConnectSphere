import SwiftUI

struct CommunityDetailView: View {
    @Environment(AppState.self) var appState
    @Environment(\.colorScheme) var colorScheme
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.appBundle) var bundle
    @State private var viewModel: CommunityDetailViewModel
    @State private var showCreatePost = false
    /// Sell was tapped in the composer: open New listing once it has closed.
    @State private var sellAfterCompose = false
    @State private var showSell = false
    @State private var showReports       = false
    @State private var showAnalytics     = false
    @State private var showSettings      = false
    @State private var showMembers       = false
    @State private var showManageRoles   = false
    @State private var showModLog        = false
    @State private var showDisband       = false
    @State private var disbandName       = ""
    @State private var showEdit          = false
    @State private var showReportCommunity = false
    @State private var showInfo          = false
    @State private var showMyContent     = false
    @State private var showRequests      = false
    @State private var showNotifications = false
    @State private var showShare         = false
    @State private var showMyProfile     = false
    /// Scrolling down hides the search field, Feed/Members and the tab bar.
    @State private var barsHidden        = false
    /// Status bar + navigation bar: the cover runs up under both.
    @State private var topInset: CGFloat = 0
    /// The header's Join button is on screen; once it scrolls away, a copy
    /// slides up from the bottom so joining doesn't mean losing your place.
    @State private var headerJoinVisible = true
    @Environment(UndoToastPresenter.self) private var toast
    @Environment(\.dismiss) private var dismiss
    // Tap-to-open-post-detail, same PostRoute/PostDetailView navigation Feed uses.
    @State private var detailRoute: PostRoute?
    /// What's looked at here, for ranking feeds.
    @State private var impressions = ImpressionTracker(source: .community)
    @Environment(\.scenePhase) private var scenePhase
    /// The full-screen search page, opened by the toolbar's magnifier.
    @State private var showSearch        = false

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

    /// A private community the viewer hasn't joined. The posts and members
    /// endpoints are 403-gated server-side, so show a "request to join" prompt
    /// rather than the misleading "No posts yet" / empty roster.
    private var isPrivateLockedOut: Bool {
        viewModel.community.map { !$0.viewerCanRead } ?? false
    }

    // MARK: - Body

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                // Pulled up under the bars rather than ignoring the safe area
                // on the scroll view, so Feed/Members still pins below them.
                communityHeader
                    .padding(.top, -topInset)

                Section {
                    if let deletion = viewModel.community?.deletionDate {
                        disbandedBanner(deletion)
                    }
                    if canCompose {
                        createPostBar
                    }
                    feedContent
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if showsFloatingJoin {
                floatingJoinBar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: showsFloatingJoin)
        // Inside a community the tab bar stays away; its own top bar still
        // slides with the scroll.
        .hidesBarsOnScroll($barsHidden, tabBarAlwaysHidden: true)
        // Back, search and "..." slide away with the tab bar while reading down.
        .toolbar(barsHidden ? .hidden : .visible, for: .navigationBar)
        // Measured with the bars showing only: hiding them shrinks the inset,
        // and the header (long scrolled past by then) shouldn't move.
        .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.top } action: { if !barsHidden { topInset = $0 } }
        .appBackground()
        .navigationBarTitleDisplayMode(.inline)
        // Back, search and "..." float on the cover.
        .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
        .hidesTopScrollEdgeEffect()
        .toolbar {
            // Like Facebook: search, then "...", no share icon.
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showSearch = true
                } label: {
                    Image(systemName: "magnifyingglass").scaledFont(17)
                }
                .accessibilityLabel(Text("Search this community", bundle: bundle))
            }
            // Staff see at a glance that something waits for review, with the
            // same badge as the Messages button (drawn outside the bar's glass).
            BadgedToolbarItem(
                button: Menu { moreMenu } label: {
                    Image(systemName: "ellipsis").scaledFont(17)
                }
                .accessibilityLabel(Text("More", bundle: bundle)),
                count: isStaff ? (viewModel.community?.staffAttentionCount ?? 0) : 0)
        }
        .task { await viewModel.fetchAll() }
        .refreshable { await viewModel.refresh() }
        .onAppear { viewModel.joinCommunityRoom() }
        .onDisappear {
            // A screen pushed from here (Members, Manage roles…) hides this
            // page but still shows its data, so stay in the room for live
            // updates; leave only when the page itself goes away.
            if !isCoveredByPush { viewModel.leaveCommunityRoom() }
            impressions.pause()
        }
        .onChange(of: scenePhase) { _, phase in if phase != .active { impressions.pause() } }
        .sheet(isPresented: $showCreatePost, onDismiss: {
            if sellAfterCompose {
                sellAfterCompose = false
                showSell = true
            }
        }) {
            if let community = viewModel.community {
                CreatePostView(community: community, onPostCreated: { post in
                    viewModel.prependPost(post)
                }, onSell: { sellAfterCompose = true })
                .environment(appState)
                .environment(themeManager)
            }
        }
        .sheet(isPresented: $showSell) {
            if let community = viewModel.community {
                // Listed in this community (already ticked) and the Marketplace.
                CreateListingView(mode: .hobby, preselectedCommunityId: community.id) { listing in
                    if listing.publishStatus != "pending" { viewModel.prependPost(listing) }
                    showSell = false
                }
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
            CommunitySettingsSheet(viewModel: viewModel, onLeft: { dismiss() },
                                   onChooseNewAdmin: { showMembers = true },
                                   onDisband: {
                                       disbandName = ""
                                       // After the sheet has gone, so the alert sits on the page.
                                       Task { try? await Task.sleep(for: .milliseconds(450)); showDisband = true }
                                   })
        }
        .sheet(isPresented: $showEdit) {
            if let community = viewModel.community {
                EditCommunityView(community: community) { viewModel.applyEdited($0) }
            }
        }
        .sheet(isPresented: $showReportCommunity) {
            ReportSheet(subject: .content(.community, id: communityId))
        }
        // Screens opened from a community keep the tab bar hidden too.
        .navigationDestination(isPresented: $showMembers) {
            CommunityMembersView(viewModel: viewModel).toolbar(.hidden, for: .tabBar)
        }
        .navigationDestination(isPresented: $showManageRoles) {
            ManageRolesView(communityId: communityId) {
                Task { await viewModel.adminTransferredElsewhere() }
            }
            .toolbar(.hidden, for: .tabBar)
        }
        // Disband confirmation (opened from Community settings, which closes first).
            .alert(bundle.loc("Disband this community?"), isPresented: $showDisband) {
                TextField(viewModel.community?.name ?? "", text: $disbandName)
                Button(bundle.loc("Cancel"), role: .cancel) {}
                Button(bundle.loc("Disband"), role: .destructive) {
                    Task {
                        if await viewModel.disband(confirmName: disbandName.trimmingCharacters(in: .whitespacesAndNewlines)) {
                            dismiss()
                        }
                    }
                }
                .disabled(disbandName.trimmingCharacters(in: .whitespacesAndNewlines) != viewModel.community?.name)
            } message: {
                Text(String(format: bundle.loc("Type \"%@\" to confirm. Members are told it was disbanded; you can restore it for 7 days."),
                            viewModel.community?.name ?? ""))
            }
        .navigationDestination(isPresented: $showModLog) {
            ModerationLogView(communityId: communityId).toolbar(.hidden, for: .tabBar)
        }
        .alert(bundle.loc("This community was disbanded"), isPresented: Binding(
            get: { viewModel.wasDisbanded }, set: { if !$0 { viewModel.wasDisbanded = false } }
        )) {
            Button(bundle.loc("OK")) { dismiss() }
        } message: {
            Text("Its admin disbanded it, so it's no longer available.", bundle: bundle)
        }
        .navigationDestination(isPresented: $showMyContent) {
            ManageCommunityContentView(communityId: communityId).toolbar(.hidden, for: .tabBar)
        }
        // Back from reviewing: the counts on the "..." menu catch up.
        .onChange(of: showRequests) { _, open in if !open { Task { await viewModel.fetchDetail() } } }
        .onChange(of: showReports) { _, open in if !open { Task { await viewModel.fetchDetail() } } }
        .navigationDestination(isPresented: $showRequests) {
            CommunityRequestsView(communityId: communityId,
                                  showsJoin: viewModel.community?.privacy == .private,
                                  postCount: viewModel.community?.pendingPostCount ?? 0,
                                  joinCount: viewModel.community?.pendingJoinCount ?? 0)
                .toolbar(.hidden, for: .tabBar)
        }
        .navigationDestination(isPresented: $showInfo) {
            if let community = viewModel.community {
                CommunityInfoView(community: community, roster: viewModel.members) {
                    CommunityMembersView(viewModel: viewModel).toolbar(.hidden, for: .tabBar)
                }
                .toolbar(.hidden, for: .tabBar)
            }
        }
        .fullScreenCover(isPresented: $showSearch) {
            if let community = viewModel.community {
                CommunitySearchView(
                    communityId: communityId,
                    communityName: community.name,
                    token: appState.authToken ?? "",
                    seedPosts: viewModel.posts)
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
        .navigationDestination(isPresented: $showReports) {
            CommunityReportsView(communityId: communityId, isAdmin: currentUserRole == .admin)
                .toolbar(.hidden, for: .tabBar)
        }
        .navigationDestination(isPresented: $showAnalytics) {
            CommunityAnalyticsView(
                communityId: viewModel.community?.id ?? "",
                token:       appState.authToken ?? "",
                coverColor:  viewModel.community?.coverColor ?? "#7F5AF0"
            )
            .toolbar(.hidden, for: .tabBar)
        }
        .alert(bundle.loc("Error"), isPresented: .constant(viewModel.errorMessage != nil)) {
            Button(bundle.loc("OK")) { viewModel.errorMessage = nil }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
    }

    /// The admin's own disbanded community: when it goes for good, and Restore.
    private func disbandedBanner(_ deletion: Date) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "archivebox.fill").foregroundColor(.red)
            VStack(alignment: .leading, spacing: 2) {
                Text("Disbanded", bundle: bundle).scaledFont(15, .semibold)
                Text(String(format: bundle.loc("Members can't see it. It's deleted for good on %@."),
                            deletion.formatted(date: .long, time: .omitted)))
                    .scaledFont(13)
                    .foregroundColor(AppColors.textSecondary(colorScheme))
            }
            Spacer()
            Button(bundle.loc("Restore")) { Task { await viewModel.restore() } }
                .buttonStyle(.borderedProminent)
        }
        .padding(14)
        .surfaceBackground()
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 12)
        .padding(.top, 10)
    }

    private var isCoveredByPush: Bool {
        showMembers || showManageRoles || showModLog || showInfo || showMyContent || showRequests
            || showReports || showAnalytics || detailRoute != nil
    }

    // MARK: - "..." menu

    /// "Pending posts · 2"; just the title when nothing is waiting.
    private func withCount(_ title: String, _ count: Int?) -> String {
        guard let count, count > 0 else { return title }
        return "\(title) · \(count)"
    }

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
                Label(bundle.loc("Manage\nnotifications"), systemImage: "bell")
            }
            Button { showSettings = true } label: {
                Label(bundle.loc("Community settings"), systemImage: "gearshape")
            }
            if isStaff {
                // Staff tools sit in one submenu, so the "..." menu stays short
                // enough that nothing is cut off at the bottom.
                Menu {
                    if currentUserRole == .admin {
                        Button { showEdit = true } label: {
                            Label(bundle.loc("Edit community"), systemImage: "pencil")
                        }
                    }
                    Button { showRequests = true } label: {
                        Label(withCount(bundle.loc("Requests"), viewModel.community?.pendingRequestCount),
                              systemImage: "tray.full")
                    }
                    Button { showReports = true } label: {
                        Label(withCount(bundle.loc("Reports"), viewModel.community?.pendingReportCount),
                              systemImage: "exclamationmark.shield")
                    }
                    // Moderators see the log too: staff keep each other accountable.
                    Button { showModLog = true } label: {
                        Label(bundle.loc("Moderation log"), systemImage: "list.bullet.rectangle")
                    }
                    if currentUserRole == .admin {
                        Button { showManageRoles = true } label: {
                            Label(bundle.loc("Manage roles"), systemImage: "person.2.badge.gearshape")
                        }
                        Button { showAnalytics = true } label: {
                            Label(bundle.loc("Analytics"), systemImage: "chart.xyaxis.line")
                        }
                    }
                } label: {
                    // Breaks between the words: the menu otherwise hyphenates "commu-nity".
                    Label(withCount(bundle.loc("Manage\ncommunity"), viewModel.community?.staffAttentionCount),
                          systemImage: "slider.horizontal.3")
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
                if community.isReadOnlyVisit || (!community.isMember && (appState.currentUser?.isOfficial ?? false)) {
                    // The official account visiting without joining: it can like,
                    // comment and share here, but not post or moderate.
                    Label(bundle.loc("Visiting as ConnectSphere"), systemImage: "checkmark.seal")
                        .scaledFont(13, .medium)
                        .foregroundColor(AppColors.textSecondary(colorScheme))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(AppColors.surface(colorScheme), in: Capsule())
                        .padding(.top, 6)
                } else if !community.isMember {
                    joinButton.padding(.top, 6)
                        .onScrollVisibilityChange(threshold: 0.2) { headerJoinVisible = $0 }
                }
            }
        } else {
            AppColors.surface(colorScheme)
                .frame(height: topInset + CommunityHeaderCard<EmptyView>.visibleCoverHeight)
        }
    }

    @ViewBuilder
    private var joinButton: some View {
        switch viewModel.joinStatus {
        case .notMember:
            VStack(spacing: 6) {
                Button {
                    Task<Void, Never>(name: nil) { await viewModel.requestToJoin() }
                } label: {
                    joinButtonLabel(
                        title: viewModel.community?.privacy == .private ? bundle.loc("Request to join") : bundle.loc("Join now"),
                        bg: themeManager.theme.primary, fg: .white
                    )
                }
                .buttonStyle(.plain)
                .disabledWhenRestricted()
                Text("You need to join a community to post", bundle: bundle)
                    .scaledFont(12)
                    .foregroundColor(AppColors.textSecondary(colorScheme))
            }

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

    /// Same visitors as the header's Join button, only while it's off screen.
    private var showsFloatingJoin: Bool {
        guard let community = viewModel.community, !community.isMember, !headerJoinVisible,
              !community.isReadOnlyVisit, !(appState.currentUser?.isOfficial ?? false) else { return false }
        return viewModel.joinStatus == .notMember || viewModel.joinStatus == .loading
    }

    private var floatingJoinBar: some View {
        Button {
            Task<Void, Never>(name: nil) { await joinFromFloatingBar() }
        } label: {
            Group {
                if viewModel.joinStatus == .loading {
                    ProgressView().tint(.white)
                } else {
                    Text(viewModel.community?.privacy == .private ? bundle.loc("Request to join") : bundle.loc("Join now"))
                }
            }
            .appFont(.subheadline)
            .fontWeight(.semibold)
            .foregroundColor(.white)
            .frame(maxWidth: .infinity, minHeight: 22)
            .padding(.vertical, AppSpacing.sm + 4)
            .background(themeManager.theme.primary)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(viewModel.joinStatus == .loading)
        .disabledWhenRestricted()
        .padding(10)
        .modifier(FloatingJoinGlass())
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    /// Joins in place: the feed and scroll position stay, the page just
    /// becomes a member's page and a toast says so.
    private func joinFromFloatingBar() async {
        await viewModel.requestToJoin()
        switch viewModel.joinStatus {
        case .joined:
            toast.show(message: String(format: bundle.loc("You joined %@"), viewModel.community?.name ?? ""))
        case .pending:
            toast.show(message: bundle.loc("Request sent"))
        default:
            break
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
            .padding(.bottom, 24)
        }
    }

    private var emptyFeed: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.text")
                .scaledFont(40)
                .foregroundColor(AppColors.textTertiary(colorScheme))
            Text("No posts yet", bundle: bundle)
                .scaledFont(16, .medium)
                .foregroundColor(AppColors.textSecondary(colorScheme))
            if viewModel.community?.isMember == true {
                Text("Be the first to post in this community!", bundle: bundle)
                    .scaledFont(14)
                    .foregroundColor(AppColors.textTertiary(colorScheme))
            }
        }
        .padding(.top, 60)
        .frame(maxWidth: .infinity)
    }

    private func privateLockedNotice(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.fill")
                .scaledFont(40)
                .foregroundColor(AppColors.textTertiary(colorScheme))
            Text(message)
                .scaledFont(15)
                .multilineTextAlignment(.center)
                .foregroundColor(AppColors.textSecondary(colorScheme))
                .padding(.horizontal, 32)
        }
        .padding(.top, 60)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Create post bar

    /// Members only: the bar sits at the top of the feed, so posting means
    /// scrolling back up to it.
    /// A disbanded community takes no new posts (the server refuses them too).
    private var canCompose: Bool { viewModel.community?.isMember == true && viewModel.community?.disbandedAt == nil }

    private var createPostBar: some View {
        HStack(spacing: 10) {
            if let me = appState.currentUser {
                AvatarView(user: me, size: 40)
            }
            Button { showCreatePost = true } label: {
                Text("What's on your mind?", bundle: bundle)
                    .scaledFont(15)
                    .foregroundColor(AppColors.textSecondary(colorScheme))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Capsule().stroke(AppColors.borderDefault(colorScheme), lineWidth: 1))
            }
            .disabledWhenRestricted()
        }
        .padding(.horizontal, AppSpacing.sm + 4)
        .padding(.vertical, 10)
        .background(AppColors.surface(colorScheme))
    }
}

private struct FloatingJoinGlass: ViewModifier {
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content.background(.ultraThinMaterial, in: shape)
        }
    }
}

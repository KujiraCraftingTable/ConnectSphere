import SwiftUI

struct CommunityDetailView: View {
    @Environment(AppState.self) var appState
    @Environment(\.colorScheme) var colorScheme
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.appBundle) var bundle
    @State private var viewModel: CommunityDetailViewModel
    @State private var selectedTab = 0
    @State private var showCreatePost = false
    @State private var showJoinRequests  = false
    @State private var showModeration    = false
    @State private var showAnalytics     = false
    @State private var reportTargetId: String? = nil
    @State private var showReportMember  = false
    // Tap-to-open-post-detail — same PostRoute/PostDetailView navigation Feed uses.
    @State private var detailRoute: PostRoute?
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

    private var accentColor: Color {
        Color(hex: viewModel.community?.coverColor ?? "#7F5AF0")
    }

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
                communityHeader

                Section(header: tabBar) {
                    if selectedTab == 0 {
                        feedContent
                    } else {
                        membersContent
                    }
                }
            }
        }
        .appBackground()
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Share link — available to any viewer (member or not), not staff-gated.
            if let shareURL = URL(string: "connectsphere://community/\(communityId)") {
                ToolbarItem(placement: .navigationBarTrailing) {
                    ShareLink(
                        item: shareURL,
                        subject: Text(viewModel.community?.name ?? bundle.loc("Community")),
                        message: Text(String(format: bundle.loc("Join %@ on ConnectSphere"), viewModel.community?.name ?? bundle.loc("Community")))
                    ) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 17))
                    }
                }
            }
            if isStaff {
                // Moderation queue (admin/mod)
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showModeration = true } label: {
                        Image(systemName: "shield.lefthalf.filled")
                            .font(.system(size: 17))
                    }
                }
                // Join-request button (admin/mod, private communities only)
                if viewModel.community?.privacy == .private {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button { showJoinRequests = true } label: {
                            Image(systemName: "person.badge.plus")
                                .font(.system(size: 17))
                        }
                    }
                }
            }
            // Analytics (admin only)
            if currentUserRole == .admin {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showAnalytics = true } label: {
                        Image(systemName: "chart.xyaxis.line")
                            .font(.system(size: 17))
                    }
                }
            }
            // Mute — hides this community's posts from the viewer's own main
            // Feed without leaving/unfollowing (see PostStore.notMutedClause);
            // available to any member, not staff-gated.
            if viewModel.community?.isMember == true {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button {
                            Task<Void, Never>(name: nil) { await viewModel.toggleMute() }
                        } label: {
                            if viewModel.community?.isMuted == true {
                                Label(bundle.loc("Unmute this community"), systemImage: "bell")
                            } else {
                                Label(bundle.loc("Mute this community"), systemImage: "bell.slash")
                            }
                        }
                    } label: {
                        Image(systemName: viewModel.community?.isMuted == true ? "bell.slash.fill" : "ellipsis")
                            .font(.system(size: 17))
                    }
                }
            }
        }
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: bundle.loc("Search posts"))
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
        .refreshable { await viewModel.fetchAll() }
        .onAppear { viewModel.joinCommunityRoom() }
        .onDisappear { viewModel.leaveCommunityRoom() }
        .overlay(alignment: .bottomTrailing) {
            if viewModel.community?.isMember == true {
                createPostFAB
            }
        }
        .sheet(isPresented: $showCreatePost) {
            if let community = viewModel.community {
                CommunityCreatePostView(community: community) { post in
                    viewModel.prependPost(post)
                }
                .environment(appState)
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
        .sheet(isPresented: $showReportMember) {
            if let memberId = reportTargetId {
                ReportSheet(
                    targetType:  "member",
                    targetId:    memberId,
                    communityId: viewModel.community?.id ?? "",
                    token:       appState.authToken ?? ""
                )
            }
        }
        .alert(bundle.loc("Error"), isPresented: .constant(viewModel.errorMessage != nil)) {
            Button(bundle.loc("OK")) { viewModel.errorMessage = nil }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
    }

    // MARK: - Header

    private var communityHeader: some View {
        ZStack(alignment: .bottomLeading) {
            AppColors.surface(colorScheme)
                .frame(height: 112)

            HStack(alignment: .bottom, spacing: AppSpacing.md) {
                // Real uploaded photo when set, else the emoji/color fallback —
                // same Avatar component every user pfp already uses.
                Avatar(name: viewModel.community?.iconEmoji ?? "👥",
                       colorHex: viewModel.community?.coverColor,
                       imageURL: viewModel.community?.avatarUrl, diameter: 60)
                    .padding(.leading, AppSpacing.lg)
                    .padding(.bottom, AppSpacing.md)

                VStack(alignment: .leading, spacing: 2) {
                    Text(viewModel.community?.name ?? "")
                        .appFont(.title3)
                        .foregroundColor(AppColors.textPrimary(colorScheme))
                    if let count = viewModel.community?.memberCount {
                        Text(String(format: bundle.loc("%lld members"), count))
                            .appFont(.footnote)
                            .foregroundColor(AppColors.textSecondary(colorScheme))
                    }
                }
                .padding(.bottom, AppSpacing.md + 2)
                Spacer()

                // Join / Request / Pending button for non-members
                if viewModel.community?.isMember == false {
                    joinButton
                        .padding(.trailing, AppSpacing.lg)
                        .padding(.bottom, AppSpacing.md)
                }
            }
        }
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
                .padding(.horizontal, AppSpacing.lg)
                .padding(.vertical, AppSpacing.sm)

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
            .padding(.horizontal, AppSpacing.md + 2)
            .padding(.vertical, AppSpacing.sm)
            .background(bg)
            .clipShape(Capsule())
    }

    // MARK: - Tab bar

    private var tabBar: some View {
        HStack(spacing: 0) {
            tabButton(title: bundle.loc("Feed"),   index: 0)
            tabButton(title: bundle.loc("Members"), index: 1)
        }
        .background(AppColors.surface(colorScheme))
        .overlay(alignment: .bottom) {
            Divider().background(AppColors.borderSubtle(colorScheme))
        }
    }

    private func tabButton(title: String, index: Int) -> some View {
        Button {
            selectedTab = index
        } label: {
            VStack(spacing: 0) {
                Text(title)
                    .font(.system(size: 15, weight: selectedTab == index ? .semibold : .regular))
                    .foregroundColor(selectedTab == index
                        ? AppColors.textPrimary(colorScheme)
                        : AppColors.textSecondary(colorScheme))
                    .padding(.vertical, 12)

                Rectangle()
                    .fill(selectedTab == index ? accentColor : Color.clear)
                    .frame(height: 2)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
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
                            detailRoute = PostRoute(postId: post.id, focusComposer: focus)
                        },
                        onPin: isStaff ? {
                            Task<Void, Never>(name: nil) { await viewModel.pinPost(post.id) }
                        } : nil,
                        onUnpin: isStaff ? {
                            Task<Void, Never>(name: nil) { await viewModel.unpinPost(post.id) }
                        } : nil
                    )
                    .cardStyle()
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
                            detailRoute = PostRoute(postId: post.id, focusComposer: focus)
                        },
                        onPin: isStaff ? {
                            Task<Void, Never>(name: nil) { await viewModel.pinPost(post.id) }
                        } : nil,
                        onUnpin: isStaff ? {
                            Task<Void, Never>(name: nil) { await viewModel.unpinPost(post.id) }
                        } : nil
                    )
                    .cardStyle()
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

    // MARK: - Members

    @ViewBuilder
    private var membersContent: some View {
        if isPrivateLockedOut {
            privateLockedNotice(bundle.loc("Members of a private community are only visible to its members."))
        } else if viewModel.isLoadingMembers {
            ProgressView().padding(.top, 40).frame(maxWidth: .infinity)
        } else {
            LazyVStack(spacing: 0) {
                ForEach(viewModel.members) { member in
                    memberRow(member)
                    Divider()
                        .background(AppColors.borderSubtle(colorScheme))
                        .padding(.leading, 60)
                }
            }
            .surfaceBackground()
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .padding(10)
        }
    }

    private func memberRow(_ member: CommunityMember) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(Color(hex: member.avatarColor))
                Text(String(member.displayName.prefix(1)))
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.white)
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(member.displayName)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(AppColors.textPrimary(colorScheme))
                Text("@\(member.username)")
                    .font(.system(size: 13))
                    .foregroundColor(AppColors.textSecondary(colorScheme))
            }
            Spacer()
            if member.role != .member {
                Text(bundle.loc(member.role.label))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(accentColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(accentColor.opacity(0.12))
                    .clipShape(Capsule())
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contextMenu { memberContextMenu(member) }
    }

    @ViewBuilder
    private func memberContextMenu(_ member: CommunityMember) -> some View {
        let isSelf  = member.id == (appState.currentUser?.id ?? "")
        let canKick = currentUserRole == .admin
                   || (currentUserRole == .moderator && member.role == .member)

        // Staff actions (not on self)
        if isStaff && !isSelf {
            // Role change — admin only
            if currentUserRole == .admin && member.role == .member {
                Button {
                    Task<Void, Never>(name: nil) { await viewModel.updateRole(userId: member.id, newRole: .moderator) }
                } label: {
                    Label(bundle.loc("Promote to moderator"), systemImage: "person.badge.shield.checkmark")
                }
            }
            if currentUserRole == .admin && member.role == .moderator {
                Button {
                    Task<Void, Never>(name: nil) { await viewModel.updateRole(userId: member.id, newRole: .member) }
                } label: {
                    Label(bundle.loc("Demote to member"), systemImage: "person.badge.minus")
                }
            }

            // Kick
            if canKick {
                Divider()
                Button(role: .destructive) {
                    Task<Void, Never>(name: nil) { await viewModel.kickMember(member.id) }
                } label: {
                    Label(bundle.loc("Remove from community"), systemImage: "person.crop.circle.badge.xmark")
                }
            }
        }

        // Report — any member can report another member (not self)
        if !isSelf {
            Divider()
            Button {
                reportTargetId  = member.id
                showReportMember = true
            } label: {
                Label(bundle.loc("Report this member"), systemImage: "flag")
            }
        }
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

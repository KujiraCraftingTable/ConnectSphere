import SwiftUI

struct UserProfileView: View {
    @Environment(AppState.self) var appState
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.appBundle) var bundle
    @State private var viewModel = ProfileViewModel()
    @Environment(\.colorScheme) var colorScheme

    let userId: String
    let preloadedUser: UserProfile?
    /// Set when opened from the person's other persona ("See Work profile"):
    /// that mode's profile, view only — connecting happens in that mode.
    let viewingMode: AppMode?
    private var mode: AppMode { viewingMode ?? appState.currentMode }
    private var otherMode: AppMode { mode == .hobby ? .work : .hobby }

    @State private var pull: CGFloat = 0
    @State private var chatConversationId: String?
    @State private var navigateToChat = false
    // Tap-to-open-post-detail — same PostRoute/PostDetailView navigation Feed uses.
    @State private var detailRoute: PostRoute?

    // Block state
    @State private var showBlockConfirm = false
    /// Relationship (friend / request / follow) with this person — shared by
    /// the card's buttons and the ••• menu's Follow item.
    @State private var connect = ConnectViewModel()
    @State private var listRoute: ProfileStat?

    private var isSelf: Bool { userId == appState.currentUser?.id }

    init(userId: String, preloadedUser: UserProfile? = nil, viewingMode: AppMode? = nil) {
        self.userId = userId
        self.preloadedUser = preloadedUser
        self.viewingMode = viewingMode
    }

    private var user: UserProfile? {
        viewModel.user ?? preloadedUser
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if let user = user {
                    VStack(spacing: 8) {
                        ProfileHeaderCard(user: user, mode: mode, onStatTap: { stat in
                            if stat == .posts { withAnimation { proxy.scrollTo("posts", anchor: .top) } }
                            // The lists are your own mode's; not from the other persona.
                            else if viewingMode == nil { listRoute = stat }
                        }) {
                            actions(for: user)
                        }
                        if viewingMode == nil, !isSelf, user.otherModeLinked(from: mode) {
                            otherProfileButton(user)
                        }
                        if mode == .work {
                            ExperienceSection(userId: user.id, isMe: user.id == appState.currentUser?.id)
                            SkillsSection(userId: user.id, isMe: user.id == appState.currentUser?.id,
                                          allowsEndorsing: viewingMode == nil)
                        }
                        postsSection.id("posts")
                    }
                } else {
                    ProgressView().padding(.top, 120)
                }
            }
            // The cover runs up under the status bar; its fade keeps it legible.
            .ignoresSafeArea(edges: .top)
            .trackPull($pull)
            .refreshable {
                await viewModel.refresh(userId: userId, mode: mode.rawValue)
                if userId != appState.currentUser?.id { await viewModel.loadBlockStatus(userId: userId) }
            }
        }
        .overlay(alignment: .top) { PullRefreshIndicator(pull: pull, isRefreshing: viewModel.isRefreshing) }
        .background(AppColors.base(colorScheme))
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .navigationDestination(item: $listRoute) { stat in
            switch stat {
            case .followers: FollowListView(userId: userId, showsFollowers: true)
            case .following: FollowListView(userId: userId, showsFollowers: false)
            default:         ConnectionsListView()
            }
        }
        .toolbar {
            if !isSelf {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        if !viewModel.isBlocked && viewingMode == nil {
                            Button {
                                Task { await connect.setFollowing(!connect.isFollowing, targetId: userId,
                                                                  mode: mode.rawValue) }
                            } label: {
                                Label(bundle.loc(connect.isFollowing ? "Unfollow" : "Follow"),
                                      systemImage: connect.isFollowing ? "person.crop.circle.badge.xmark"
                                                                       : "person.crop.circle.badge.plus")
                            }
                        }
                        if viewModel.isBlocked {
                            Button {
                                Task { await viewModel.toggleBlock(userId: userId) }
                            } label: {
                                Label(bundle.loc("Unblock"), systemImage: "person.crop.circle.badge.checkmark")
                            }
                        } else {
                            Button(role: .destructive) {
                                showBlockConfirm = true
                            } label: {
                                Label(bundle.loc("Block user"), systemImage: "nosign")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(AppColors.textPrimary(colorScheme))
                    }
                }
            }
        }
        .alert(
            bundle.loc("Block this user?"),
            isPresented: $showBlockConfirm
        ) {
            Button(bundle.loc("Block"), role: .destructive) {
                Task { await viewModel.toggleBlock(userId: userId) }
            }
            Button(bundle.loc("Cancel"), role: .cancel) {}
        } message: {
            Text("You two will no longer see each other's posts, all connections will be removed, and you won't be able to message each other.", bundle: bundle)
        }
        .alert(bundle.loc("Error"), isPresented: .constant(viewModel.actionError != nil)) {
            Button(bundle.loc("OK")) { viewModel.actionError = nil }
        } message: {
            Text(viewModel.actionError ?? "")
        }
        .navigationDestination(isPresented: Binding(
            get: { detailRoute != nil },
            set: { if !$0 { detailRoute = nil } }
        )) {
            if let route = detailRoute {
                PostDetailView(postId: route.postId, focusComposer: route.focusComposer)
            }
        }
        .navigationDestination(isPresented: $navigateToChat) {
            if let convId = chatConversationId, let user = user {
                ChatView(
                    conversationId: convId,
                    peer: .direct(otherUserId: userId, name: user.name,
                                  avatarColor: user.avatarColor, avatarUrl: user.avatarUrl),
                    otherUserLocation: user.location,
                    currentUserId: appState.currentUser?.id ?? "",
                    token: appState.authToken ?? ""
                )
            }
        }
        .task {
            await viewModel.load(userId: userId, mode: mode.rawValue)
            if userId != appState.currentUser?.id {
                await viewModel.loadBlockStatus(userId: userId)
            }
        }
        .onChange(of: appState.currentMode) { _, newMode in
            // The other persona's page is pinned to its mode.
            guard viewingMode == nil else { return }
            Task { await viewModel.load(userId: userId, mode: newMode.rawValue) }
        }
    }

    // MARK: Card buttons

    @ViewBuilder
    private func actions(for user: UserProfile) -> some View {
        if isSelf {
            EmptyView()
        } else if let viewingMode {
            // View only: connecting / messaging happens in that mode.
            Label(String(format: bundle.loc(viewingMode == .work
                    ? "You're viewing %@'s Work profile. Switch to Work mode to connect."
                    : "You're viewing %@'s Hobby profile. Switch to Hobby mode to connect."), user.name),
                  systemImage: viewingMode.glyph)
                .font(.system(size: 13))
                .foregroundColor(AppColors.textSecondary(colorScheme))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(AppColors.elevated(colorScheme),
                            in: RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
        } else if viewModel.isBlocked {
            // Blocked → can no longer connect with or message this person.
            Text("Blocked", bundle: bundle)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(AppColors.danger(colorScheme))
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(AppColors.danger(colorScheme).opacity(0.12),
                            in: RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
        } else {
            ProfileActionBar(targetUserId: userId, targetName: user.name, connect: connect,
                             isOpeningChat: viewModel.isOpeningChat) { openChat() }
        }
    }

    /// "See Work profile" / "See Hobby profile": the person's other persona, view only.
    private func otherProfileButton(_ user: UserProfile) -> some View {
        NavigationLink {
            UserProfileView(userId: userId, viewingMode: otherMode)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: otherMode.glyph)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(themeManager.theme.primary)
                Text(bundle.loc(otherMode == .work ? "See Work profile" : "See Hobby profile"))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(AppColors.textPrimary(colorScheme))
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(AppColors.textTertiary(colorScheme))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(AppColors.surface(colorScheme),
                        in: RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
            .padding(.horizontal, 12)
        }
        .buttonStyle(.plain)
    }

    private func openChat() {
        Task {
            guard let convId = await viewModel.openConversation(
                with: userId, mode: appState.currentMode, token: appState.authToken) else { return }
            chatConversationId = convId
            navigateToChat = true
        }
    }

    // MARK: Posts

    @ViewBuilder
    private var postsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Posts", bundle: bundle)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(AppColors.textPrimary(colorScheme))
                if !viewModel.isLoading {
                    Text("\(viewModel.posts.count)")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(AppColors.textSecondary(colorScheme))
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)

            if viewModel.isLoading && viewModel.posts.isEmpty {
                ProgressView().padding(.top, 20).frame(maxWidth: .infinity)
            } else if let error = viewModel.error, viewModel.posts.isEmpty {
                // A single failed load (e.g. a dropped connection) otherwise
                // left this permanently stuck empty — .task only fires once
                // per view identity, so navigating away and back doesn't
                // retry on its own.
                postsErrorState(error)
            } else {
                LazyVStack(spacing: AppSpacing.sm) {
                    ForEach(viewModel.posts) { post in
                        PostCard(
                            post: post,
                            onPostDeleted: { viewModel.removePost(id: post.id) },
                            onPostUpdated: { updated in viewModel.updatePost(updated) },
                            onOpenDetail: { focus in
                                detailRoute = PostRoute(postId: post.id, focusComposer: focus)
                            }
                        )
                        .cardStyle()
                        .onAppear {
                            if post.id == viewModel.posts.last?.id {
                                Task {
                                    await viewModel.loadMorePosts(userId: userId, mode: mode.rawValue)
                                }
                            }
                        }
                    }

                    if viewModel.isLoadingMore {
                        ProgressView().padding(.vertical, 12)
                    }
                }
                .padding(.horizontal, AppSpacing.sm)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 16)
    }

    private func postsErrorState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 32))
                .foregroundColor(AppColors.textTertiary(colorScheme))
            Text(message)
                .font(.system(size: 14))
                .multilineTextAlignment(.center)
                .foregroundColor(AppColors.textSecondary(colorScheme))
                .padding(.horizontal, 32)
            Button(bundle.loc("Retry")) {
                Task { await viewModel.load(userId: userId, mode: mode.rawValue) }
            }
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(themeManager.theme.primary)
        }
        .padding(.top, 24)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
    }
}

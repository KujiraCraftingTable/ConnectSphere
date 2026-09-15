import SwiftUI

struct FeedView: View {
    @Environment(AppState.self) var appState
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.appBundle) var bundle
    @State private var viewModel = FeedViewModel()
    @Environment(\.colorScheme) var colorScheme
    @State private var showCreatePost = false
    @State private var showMessages = false
    @State private var detailRoute: PostRoute?
    @Binding var selectedTab: Int
    /// Mode-scoped "my" profile for the create-post bar's avatar — mirrors
    /// StoriesRow.myProfile. appState.currentUser is a single unscoped cache
    /// (never refetched on mode switch), so it can't be used directly for
    /// any per-mode avatar/name display — see the StoriesRow fix for the
    /// same bug in "Your Story".
    @State private var myProfile: UserProfile?
    private let profileRepo = ProfileRepository()

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: AppSpacing.sm) {
                    Color.clear.frame(height: 0).id("feedTop")
                    createPostBar
                        .cardStyle()

                    // Stories are mode-scoped (like posts) — shown in both
                    // Hobby and Work, each mode only ever seeing its own.
                    StoriesRow()
                        .cardStyle()

                    feedScopeRow

                    if viewModel.isLoading && viewModel.posts(for: appState.currentMode).isEmpty {
                        ProgressView()
                            .padding(.top, 40)
                    } else if let error = viewModel.error, viewModel.posts(for: appState.currentMode).isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "wifi.exclamationmark")
                                .font(.system(size: 36))
                                .foregroundColor(AppColors.textTertiary(colorScheme))
                            Text(error)
                                .font(.system(size: 14))
                                .multilineTextAlignment(.center)
                                .foregroundColor(AppColors.textSecondary(colorScheme))
                                .padding(.horizontal, 32)
                            Button(bundle.loc("Retry")) {
                                Task { await viewModel.loadPosts(for: appState.currentMode) }
                            }
                            .font(.system(size: 14, weight: .semibold))
                        }
                        .padding(.top, 40)
                    } else if viewModel.posts(for: appState.currentMode).isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "person.2")
                                .font(.system(size: 36))
                                .foregroundColor(AppColors.textSecondary(colorScheme).opacity(0.4))
                            Text(bundle.loc("No posts yet"))
                                .font(.system(size: 14))
                                .foregroundColor(AppColors.textSecondary(colorScheme))
                        }
                        .padding(.top, 40)
                    } else {
                        let posts = viewModel.posts(for: appState.currentMode)
                        ForEach(posts) { post in
                            PostCard(
                                post: post,
                                onOwnAvatarTapped: { selectedTab = 4 },
                                onPostDeleted: { viewModel.removePost(id: post.id) },
                                onPostUpdated: { updated in viewModel.updatePost(updated) },
                                onOpenDetail: { focus in
                                    detailRoute = PostRoute(postId: post.id, focusComposer: focus)
                                }
                            )
                            .cardStyle()
                            // Makes a just-created post visibly slide/fade in at
                            // the top instead of silently popping into place —
                            // the "yes, this actually posted" confirmation.
                            .transition(.move(edge: .top).combined(with: .opacity))
                            .onAppear {
                                // Scrolled to the last post → load the next page
                                if post.id == posts.last?.id {
                                    Task { await viewModel.loadMorePosts(for: appState.currentMode) }
                                }
                            }
                        }

                        if viewModel.isLoadingMore {
                            ProgressView().padding(.vertical, 12)
                        }
                    }
                }
                .padding(.horizontal, AppSpacing.sm)
                .padding(.bottom, AppSpacing.lg)
            }
            .background(AppColors.base(colorScheme))
            .scrollIndicators(.hidden)
            .navigationBarTitleDisplayMode(.inline)
            .refreshable {
                await viewModel.loadPosts(for: appState.currentMode)
            }
            .task {
                await viewModel.loadPostsIfNeeded(for: appState.currentMode)
                await loadMyProfile(mode: appState.currentMode)
            }
            .onChange(of: appState.currentMode) { _, newMode in
                withAnimation(.easeInOut(duration: 0.4)) {
                    proxy.scrollTo("feedTop", anchor: .top)
                }
                Task {
                    await viewModel.loadPosts(for: newMode)
                }
                Task {
                    guard let token = appState.authToken else { return }
                    appState.chatUnreadCount = (try? await MessageRepository().fetchUnreadCount(
                        mode: newMode.rawValue, token: token
                    )) ?? 0
                }
                Task {
                    await loadMyProfile(mode: newMode)
                }
            }
            .onChange(of: viewModel.feedScope) { _, _ in
                withAnimation(.easeInOut(duration: 0.4)) {
                    proxy.scrollTo("feedTop", anchor: .top)
                }
                Task {
                    await viewModel.loadPosts(for: appState.currentMode)
                }
            }
            // Inside `ScrollViewReader`'s scope so `proxy` is reachable —
            // posting used to only trigger a silent background reload, which
            // left the new post above the fold (or racing a reload the user
            // never saw finish) and was the whole reason this felt broken:
            // no confirmation short of leaving the feed to check Profile.
            // Now the post is inserted immediately (no network round-trip to
            // even see it) and the feed animates back to the top to show it.
            .sheet(isPresented: $showCreatePost) {
                CreatePostView(onPostCreated: { post in
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                        // Use the post's OWN mode (as the server actually recorded it),
                        // not appState.currentMode re-read at completion time — the two
                        // could in principle diverge if the mode changed while the
                        // composer sheet was open.
                        viewModel.prependPost(post, for: post.mode)
                    }
                    withAnimation(.easeInOut(duration: 0.4)) {
                        proxy.scrollTo("feedTop", anchor: .top)
                    }
                })
                .environment(appState)
            }
            } // ScrollViewReader
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    modeSwitchPill
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    chatIconButton
                }
            }
            .navigationDestination(isPresented: $showMessages) {
                ConversationListView()
            }
            // `isPresented:` (not `item:`) so it doesn't collide with the
            // identical PostRoute destination TagFeedView also puts on this
            // same stack — SwiftUI keeps only the root-most `item:` of a type.
            .navigationDestination(isPresented: Binding(
                get: { detailRoute != nil },
                set: { if !$0 { detailRoute = nil } }
            )) {
                if let route = detailRoute {
                    PostDetailView(postId: route.postId, focusComposer: route.focusComposer)
                }
            }
            .onAppear {
                setupChatBadge()
            }
            .onDisappear {
                WebSocketClient.shared.off("new_message", tag: "feedBadge")
            }
        }
    }

    /// Mode-scoped fetch for the create-post bar's own avatar — same pattern
    /// as StoriesRow.load()'s profile fetch.
    private func loadMyProfile(mode: AppMode) async {
        guard let id = appState.currentUser?.id else { return }
        myProfile = try? await profileRepo.fetchUser(userId: id, mode: mode.rawValue)
    }

    // MARK: Chat badge — connect socket, register real-time handler, fetch count

    private func setupChatBadge() {
        guard let token = appState.authToken else { return }
        let mode = appState.currentMode.rawValue
        WebSocketClient.shared.connect(token: token)
        WebSocketClient.shared.on("new_message", tag: "feedBadge") { [appState] _ in
            Task { @MainActor in
                guard let t = appState.authToken else { return }
                appState.chatUnreadCount = (try? await MessageRepository().fetchUnreadCount(
                    mode: appState.currentMode.rawValue, token: t
                )) ?? 0
            }
        }
        Task {
            appState.chatUnreadCount = (try? await MessageRepository().fetchUnreadCount(
                mode: mode, token: token
            )) ?? 0
        }
    }

    // MARK: Mode Switch Pill (leading edge of nav bar, icon-only)

    private var modeSwitchPill: some View {
        HStack(spacing: 0) {
            modePillButton(mode: .hobby, icon: AppMode.hobby.glyph, label: bundle.loc("Hobby"))
            modePillButton(mode: .work, icon: AppMode.work.glyph, label: bundle.loc("Work"))
        }
        .background(AppColors.surface(colorScheme), in: Capsule())
        .padding(.vertical, 4)
    }

    private func modePillButton(mode: AppMode, icon: String, label: String) -> some View {
        let isActive = appState.currentMode == mode
        return Button {
            withAnimation(.spring(response: 0.3)) {
                // The target mode's persona isn't set up yet → AppState shows the creation form first
                appState.requestModeSwitch(to: mode)
            }
        } label: {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(isActive ? .white : AppColors.textSecondary(colorScheme))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isActive ? themeManager.theme.primary : Color.clear, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    // MARK: Feed Scope Row ("For you" / "Connections")

    private var feedScopeRow: some View {
        HStack(spacing: 8) {
            feedScopeButton(.forYou, label: bundle.loc("For you"))
            feedScopeButton(.connections, label: bundle.loc("Connections"))
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 2)
    }

    private func feedScopeButton(_ scope: FeedScope, label: String) -> some View {
        let isActive = viewModel.feedScope == scope
        return Button {
            guard viewModel.feedScope != scope else { return }
            viewModel.feedScope = scope
        } label: {
            Text(label)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(isActive ? .white : AppColors.textSecondary(colorScheme))
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(isActive ? themeManager.theme.primary : AppColors.surface(colorScheme), in: Capsule())
                .overlay(
                    Capsule().stroke(AppColors.borderDefault(colorScheme), lineWidth: isActive ? 0 : 1)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: Create Post Bar

    private var createPostBar: some View {
        HStack(spacing: 10) {
            AvatarView(user: myProfile ?? appState.currentUser ?? MockData.currentUser, size: 40)

            Button { showCreatePost = true } label: {
                Text(appState.currentMode == .hobby
                     ? bundle.loc("What's on your mind?")
                     : bundle.loc("Share a professional update..."))
                    .font(.system(size: 15))
                    .foregroundColor(AppColors.textSecondary(colorScheme))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        Capsule().stroke(AppColors.borderDefault(colorScheme), lineWidth: 1)
                    )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var chatIconButton: some View {
        Button { showMessages = true } label: {
            ZStack(alignment: .topTrailing) {
                ZStack {
                    Circle().fill(AppColors.elevated(colorScheme)).frame(width: 36, height: 36)
                    Image(systemName: "message.fill")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(AppColors.textPrimary(colorScheme))
                }
                CountBadge(count: appState.chatUnreadCount)
                    .offset(x: 6, y: -6)
            }
        }
    }
}

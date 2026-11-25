import SwiftUI

struct FeedView: View {
    @Environment(AppState.self) var appState
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.appBundle) var bundle
    @State private var viewModel = FeedViewModel()
    @State private var people = PeopleSuggestionsViewModel()
    @Environment(\.colorScheme) var colorScheme
    @State private var showCreatePost = false
    @State private var showMessages = false
    @State private var detailRoute: PostRoute?
    /// What's looked at here, for ranking the feed.
    @State private var impressions = ImpressionTracker(source: .home)
    @Environment(\.scenePhase) private var scenePhase
    /// The tab bar (and the mode switch) slide away while reading down the
    /// feed and come back on the way up (or near the top).
    @State private var tabBarHidden = false
    @Binding var selectedTab: Int
    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: AppSpacing.sm) {
                    Color.clear.frame(height: 0).id("feedTop")

                    RestrictionBanner()

                    createPostBar
                        .cardStyle()

                    // Stories are mode-scoped (like posts). Shown in both
                    // Hobby and Work, each mode only ever seeing its own.
                    StoriesRow()
                        .cardStyle()

                    // The official account has no connections and follows no one:
                    // For you is its only feed, so there's nothing to pick.
                    if !isOfficial { feedScopeRow }

                    if viewModel.isLoading && viewModel.posts(for: appState.currentMode).isEmpty {
                        SkeletonPostList(count: 3, colorScheme: colorScheme)
                            .padding(.horizontal, 8)
                    } else if let error = viewModel.error, viewModel.posts(for: appState.currentMode).isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "wifi.exclamationmark")
                                .scaledFont(36)
                                .foregroundColor(AppColors.textTertiary(colorScheme))
                            Text(error)
                                .scaledFont(14)
                                .multilineTextAlignment(.center)
                                .foregroundColor(AppColors.textSecondary(colorScheme))
                                .padding(.horizontal, 32)
                            Button(bundle.loc("Retry")) {
                                Task { await viewModel.loadPosts(for: appState.currentMode) }
                            }
                            .scaledFont(14, .semibold)
                        }
                        .padding(.top, 40)
                    } else if viewModel.posts(for: appState.currentMode).isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "person.2")
                                .scaledFont(36)
                                .foregroundColor(AppColors.textSecondary(colorScheme).opacity(0.4))
                            Text(bundle.loc(viewModel.feedScope == .following
                                            ? "Follow people to see their public posts here"
                                            : "No posts yet"))
                                .scaledFont(14)
                                .foregroundColor(AppColors.textSecondary(colorScheme))
                        }
                        .axID(AXID.Feed.empty)
                        .padding(.top, 40)
                    } else {
                        let posts = viewModel.posts(for: appState.currentMode)
                        let slots = people.slots(for: appState.currentMode, postCount: posts.count)
                        ForEach(Array(posts.enumerated()), id: \.element.id) { index, post in
                            if !isOfficial, let appearance = slots.firstIndex(of: index) {
                                PeopleYouMayKnowRow(viewModel: people, mode: appState.currentMode, appearance: appearance)
                            }
                            feedPostCard(post, isLast: post.id == posts.last?.id)
                        }
                        if !isOfficial, let appearance = slots.firstIndex(of: posts.count) {
                            PeopleYouMayKnowRow(viewModel: people, mode: appState.currentMode, appearance: appearance)
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
            .hidesBarsOnScroll($tabBarHidden)
            // No bar behind the top buttons: while scrolling, only the floating
            // message button stays (the mode switch hides with the tab bar).
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .hidesTopScrollEdgeEffect()
            .refreshable {
                async let suggestions: Void = people.refresh(appState.currentMode)
                await viewModel.loadPosts(for: appState.currentMode)
                await suggestions
            }
            .task {
                // Posts first: they mustn't wait on the suggestions' vector query.
                let mode = appState.currentMode
                await viewModel.loadPostsIfNeeded(for: mode)
                async let profile: Void = viewModel.loadMyProfile(userId: appState.currentUser?.id, mode: mode)
                if people.suggestions[mode] == nil { await people.refresh(mode) }
                await profile
            }
            .onChange(of: appState.currentMode) { _, newMode in
                withAnimation(.easeInOut(duration: 0.4)) {
                    proxy.scrollTo("feedTop", anchor: .top)
                }
                Task {
                    await viewModel.loadPosts(for: newMode)
                }
                Task { await people.refresh(newMode) }
                Task { await viewModel.refreshChatUnread(appState: appState) }
                Task {
                    await viewModel.loadMyProfile(userId: appState.currentUser?.id, mode: newMode)
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
            // Home re-tapped: back to the top and a fresh load, which is also
            // when new suggestions get their turn at the top of the feed.
            .onChange(of: appState.shouldResetFeed) { _, reset in
                guard reset else { return }
                appState.shouldResetFeed = false
                withAnimation(.easeInOut(duration: 0.4)) {
                    proxy.scrollTo("feedTop", anchor: .top)
                }
                Task { await people.refresh(appState.currentMode) }
                Task { await viewModel.loadPosts(for: appState.currentMode) }
            }
            // Inside `ScrollViewReader`'s scope so `proxy` is reachable,
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
                        // not appState.currentMode re-read at completion time. The two
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
                // Goes away with the tab bar while reading down the feed.
                if !tabBarHidden {
                    ToolbarItem(placement: .navigationBarLeading) {
                        modeSwitchPill
                    }
                }
                // Search lives only in the Search tab. No second entry here.
                BadgedToolbarItem(button: chatIconButton, count: appState.chatUnreadCount)
            }
            .navigationDestination(isPresented: $showMessages) {
                ConversationListView()
            }
            // `isPresented:` (not `item:`) so it doesn't collide with the
            // identical PostRoute destination TagFeedView also puts on this
            // same stack, SwiftUI keeps only the root-most `item:` of a type.
            .navigationDestination(isPresented: Binding(
                get: { detailRoute != nil },
                set: { if !$0 { detailRoute = nil } }
            )) {
                if let route = detailRoute {
                    PostDetailView(postId: route.postId, focusComposer: route.focusComposer)
                }
            }
            .onAppear {
                viewModel.startChatBadge(appState: appState)
            }
            .onDisappear {
                viewModel.stopChatBadge()
                impressions.pause()
            }
            .onChange(of: scenePhase) { _, phase in if phase != .active { impressions.pause() } }
            .alert(bundle.loc("Error"), isPresented: Binding(
                get: { people.error != nil }, set: { if !$0 { people.error = nil } }
            )) {
                Button(bundle.loc("OK")) {}
            } message: {
                Text(people.error ?? "")
            }
        }
    }

    // MARK: Mode Switch Pill (leading edge of nav bar, icon-only)

    private var modeSwitchPill: some View {
        // No fill of our own: the toolbar's Liquid Glass is the only
        // background; the active mode keeps its theme-colour highlight.
        HStack(spacing: 0) {
            modePillButton(mode: .hobby, icon: AppMode.hobby.glyph, label: bundle.loc("Hobby"))
            modePillButton(mode: .work, icon: AppMode.work.glyph, label: bundle.loc("Work"))
        }
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
                .scaledFont(11, .semibold)
                .foregroundColor(isActive ? .white : AppColors.textSecondary(colorScheme))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isActive ? themeManager.theme.primary : Color.clear, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isActive ? .isSelected : [])
        .axID(AXID.Feed.mode + mode.rawValue)
    }

    /// Signed in as the official account: no suggestions, no feed scopes.
    private var isOfficial: Bool { appState.currentUser?.isOfficial ?? false }

    // MARK: Feed Scope Row ("For you" / "Connections" / "Following")

    private var feedScopeRow: some View {
        HStack(spacing: 8) {
            feedScopeButton(.forYou, label: bundle.loc("For you"))
            feedScopeButton(.connections, label: bundle.loc("Connections"))
            feedScopeButton(.following, label: bundle.loc("Following"))
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
                .scaledFont(13, .semibold)
                .foregroundColor(isActive ? .white : AppColors.textSecondary(colorScheme))
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(isActive ? themeManager.theme.primary : AppColors.surface(colorScheme), in: Capsule())
                .overlay(
                    Capsule().stroke(AppColors.borderDefault(colorScheme), lineWidth: isActive ? 0 : 1)
                )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isActive ? .isSelected : [])
        .axID(AXID.Feed.scope + scope.rawValue)
    }

    // MARK: Create Post Bar

    private var createPostBar: some View {
        HStack(spacing: 10) {
            AvatarView(user: viewModel.myProfile ?? appState.currentUser ?? MockData.currentUser, size: 40)

            Button { showCreatePost = true } label: {
                Text(appState.currentMode == .hobby
                     ? bundle.loc("What's on your mind?")
                     : bundle.loc("Share a professional update..."))
                    .scaledFont(15)
                    .foregroundColor(AppColors.textSecondary(colorScheme))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        Capsule().stroke(AppColors.borderDefault(colorScheme), lineWidth: 1)
                    )
            }
            .disabledWhenRestricted()
            .axID(AXID.Feed.composerBar)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var chatIconButton: some View {
        Button { showMessages = true } label: {
            // Bare glyph on the toolbar's glass (no circle of our own).
            Image(systemName: "message.fill")
                .scaledFont(15, .medium)
                .foregroundColor(AppColors.textPrimary(colorScheme))
        }
        .accessibilityLabel(Bundle.app.loc("Messages"))
        .axID(AXID.Chat.inboxButton)
    }

    @ViewBuilder
    private func feedPostCard(_ post: Post, isLast: Bool) -> some View {
        PostCard(
            post: post,
            onOwnAvatarTapped: { selectedTab = 4 },
            onPostDeleted: { viewModel.removePost(id: post.id) },
            onPostUpdated: { updated in viewModel.updatePost(updated) },
            onOpenDetail: { focus in
                impressions.opened(post.id)
                detailRoute = PostRoute(postId: post.id, focusComposer: focus)
            },
            showConnectButton: false
        )
        .cardStyle()
        // A container, so the card's own buttons stay reachable inside it.
        .accessibilityElement(children: .contain)
        .axID(AXID.Feed.postCell + post.id)
        .tracksImpression(post.id, in: impressions)
        // Makes a just-created post visibly slide/fade in at the top instead
        // of silently popping into place. The "yes, this actually posted"
        // confirmation.
        .transition(.move(edge: .top).combined(with: .opacity))
        .onAppear {
            // Scrolled to the last post → load the next page
            if isLast {
                Task { await viewModel.loadMorePosts(for: appState.currentMode) }
            }
        }
    }
}

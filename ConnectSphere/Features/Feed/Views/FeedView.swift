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
                            Text(bundle.loc(viewModel.feedScope == .following
                                            ? "Follow people to see their public posts here"
                                            : "No posts yet"))
                                .font(.system(size: 14))
                                .foregroundColor(AppColors.textSecondary(colorScheme))
                        }
                        .padding(.top, 40)
                    } else {
                        let posts = viewModel.posts(for: appState.currentMode)
                        let slots = people.slots(for: appState.currentMode, postCount: posts.count)
                        ForEach(Array(posts.enumerated()), id: \.element.id) { index, post in
                            if let appearance = slots.firstIndex(of: index) {
                                PeopleYouMayKnowRow(viewModel: people, mode: appState.currentMode, appearance: appearance)
                            }
                            feedPostCard(post, isLast: post.id == posts.last?.id)
                        }
                        if let appearance = slots.firstIndex(of: posts.count) {
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
            .refreshable {
                async let suggestions: Void = people.refresh(appState.currentMode)
                await viewModel.loadPosts(for: appState.currentMode)
                await suggestions
            }
            .task {
                if people.suggestions[appState.currentMode] == nil { await people.refresh(appState.currentMode) }
                await viewModel.loadPostsIfNeeded(for: appState.currentMode)
                await viewModel.loadMyProfile(userId: appState.currentUser?.id, mode: appState.currentMode)
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
                // Goes away with the tab bar while reading down the feed.
                if !tabBarHidden {
                    ToolbarItem(placement: .navigationBarLeading) {
                        modeSwitchPill
                    }
                }
                // Search lives only in the Search tab — no second entry here.
                FeedChatToolbarItem(button: chatIconButton, unread: appState.chatUnreadCount)
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
                viewModel.startChatBadge(appState: appState)
            }
            .onDisappear { viewModel.stopChatBadge() }
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
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(isActive ? .white : AppColors.textSecondary(colorScheme))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isActive ? themeManager.theme.primary : Color.clear, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

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
            AvatarView(user: viewModel.myProfile ?? appState.currentUser ?? MockData.currentUser, size: 40)

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
            // Bare glyph on the toolbar's glass (no circle of our own).
            Image(systemName: "message.fill")
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(AppColors.textPrimary(colorScheme))
        }
    }

    @ViewBuilder
    private func feedPostCard(_ post: Post, isLast: Bool) -> some View {
        PostCard(
            post: post,
            onOwnAvatarTapped: { selectedTab = 4 },
            onPostDeleted: { viewModel.removePost(id: post.id) },
            onPostUpdated: { updated in viewModel.updatePost(updated) },
            onOpenDetail: { focus in
                detailRoute = PostRoute(postId: post.id, focusComposer: focus)
            },
            showConnectButton: false
        )
        .cardStyle()
        // Makes a just-created post visibly slide/fade in at the top instead
        // of silently popping into place — the "yes, this actually posted"
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

/// The Feed's message button with its unread badge, Messenger-style: a red
/// count on the button's top-right corner, fully visible. On iOS 26 the bar
/// puts each item on a shared glass circle that clips anything sticking out
/// of it, so the item draws its own glass circle instead (shared background
/// hidden) and the badge sits on its edge.
private struct FeedChatToolbarItem<Content: View>: ToolbarContent {
    let button: Content
    let unread: Int

    var body: some ToolbarContent {
        if #available(iOS 26.0, *) {
            ToolbarItem(placement: .navigationBarTrailing) {
                button
                    .frame(width: 44, height: 44)
                    .glassEffect(.regular.interactive(), in: Circle())
                    .overlay(alignment: .topTrailing) {
                        UnreadBadge(count: unread).offset(x: 6, y: -4)
                    }
            }
            .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .navigationBarTrailing) {
                button.overlay(alignment: .topTrailing) {
                    UnreadBadge(count: unread).offset(x: 8, y: -6)
                }
            }
        }
    }
}

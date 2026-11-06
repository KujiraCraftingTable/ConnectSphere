import SwiftUI

/// Push-able destinations on `ProfileView`'s `NavigationStack`, addressable by
/// the AI assistant's navigation actions (`MainTabView
/// .consumePendingAssistantNavigation`) via the same `navPath.append`/
/// `navigationDestination(for:)` mechanism the community deep link already
/// uses. These are purely additive alongside the existing manual-tap
/// `NavigationLink`s in `SettingsView`/`PrivacySecurityView` (e.g. Blocked
/// Users is still also reachable by tapping through Privacy & Security as
/// before), both push mechanisms coexist safely on the same stack.
enum ProfileRoute: Hashable {
    case settings
    case privacySecurity
    case blockedUsers
    case notificationSettings
    case friends
    case followers
    case following
}

struct ProfileView: View {
    @Environment(AppState.self) var appState
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.appBundle) var bundle
    @State private var viewModel = ProfileViewModel()
    /// The back of your card: your other persona as others see it.
    @State private var otherViewModel = ProfileViewModel()
    @State private var showingOther = false
    @State private var flipAngle: Double = 0
    @Environment(\.colorScheme) var colorScheme
    @State private var pull: CGFloat = 0
    @State private var showCreatePost = false
    @State private var showEditProfile = false
    // Tap-to-open-post-detail, same PostRoute/PostDetailView navigation Feed uses.
    @State private var detailRoute: PostRoute?

    /// Binding from MainTabView. Resets to root whenever the tab is reselected
    @Binding var navPath: NavigationPath

    /// Only `viewModel.user`, no fallback to `appState.currentUser`, which
    /// is resolved server-side against the account's stored `default_mode`
    /// (GET /auth/me has no mode param), not the live `appState.currentMode`.
    /// Falling back to it flashed the other mode's name/bio for a moment
    /// right after switching modes. `viewModel.load()` is always in flight
    /// by the time this matters, so a brief loading state here is honest
    /// instead of showing possibly-wrong data.
    private var user: UserProfile? { viewModel.user }

    private var otherMode: AppMode { appState.currentMode == .hobby ? .work : .hobby }
    /// The mode of the side being shown.
    private var mode: AppMode { showingOther ? otherMode : appState.currentMode }
    private var shown: ProfileViewModel { showingOther ? otherViewModel : viewModel }
    private var hasOther: Bool { appState.currentUser?.hasPersona(otherMode) ?? false }

    /// Turns the card edge-on, swaps the side, turns it back.
    private func flip() {
        Task {
            withAnimation(.easeIn(duration: 0.18)) { flipAngle = 90 }
            try? await Task.sleep(for: .milliseconds(180))
            showingOther.toggle()
            flipAngle = -90
            withAnimation(.easeOut(duration: 0.22)) { flipAngle = 0 }
            if showingOther, hasOther, otherViewModel.user == nil {
                await otherViewModel.load(userId: currentUserId, mode: otherMode.rawValue)
            }
        }
    }

    private var flipButton: ProfileHeaderCard<AnyView>.Flip {
        .init(to: showingOther ? appState.currentMode : otherMode) { flip() }
    }

    /// Used only where posts-section closures need an id while `user` may
    /// still be nil (loading). This is always the signed-in account's own
    /// profile (ProfileViewModel is never used for anyone else's).
    private var currentUserId: String { appState.currentUser?.id ?? "" }

    var body: some View {
        NavigationStack(path: $navPath) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 8) {
                        if showingOther && !hasOther {
                            noOtherProfileCard
                                .rotation3DEffect(.degrees(flipAngle), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
                        } else if let user = showingOther ? otherViewModel.user : user {
                            ProfileHeaderCard(user: user, mode: mode, onStatTap: { stat in
                                switch stat {
                                case .posts:     withAnimation { proxy.scrollTo("posts", anchor: .top) }
                                // The lists belong to the mode you're in.
                                case .friends:   if !showingOther { navPath.append(ProfileRoute.friends) }
                                case .followers: if !showingOther { navPath.append(ProfileRoute.followers) }
                                case .following: if !showingOther { navPath.append(ProfileRoute.following) }
                                }
                            }, flip: flipButton) {
                                AnyView(cardActions)
                            }
                            .rotation3DEffect(.degrees(flipAngle), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
                            // Your other side is a preview: nothing to edit there.
                            if mode == .work {
                                ExperienceSection(userId: user.id, isMe: !showingOther)
                                SkillsSection(userId: user.id, isMe: !showingOther, refreshKey: user.skills)
                            }
                            if mode == .hobby {
                                HobbyAboutSection(user: user, isMe: !showingOther)
                                HighlightsRow(userId: user.id, isMe: !showingOther)
                            }
                            postsSection.id("posts")
                        } else {
                            SkeletonPostList(count: 2, colorScheme: colorScheme)
                                .padding(.horizontal, 8).padding(.top, 24)
                        }
                    }
                }
                // The cover runs up under the status bar; its own fade keeps
                // the clock and the floating nav button legible.
                .ignoresSafeArea(edges: .top)
                .trackPull($pull)
                .refreshable {
                    if let userId = appState.currentUser?.id {
                        await viewModel.refresh(userId: userId, mode: appState.currentMode.rawValue)
                    }
                }
            }
            .overlay(alignment: .top) { PullRefreshIndicator(pull: pull, isRefreshing: viewModel.isRefreshing) }
            .background(AppColors.base(colorScheme))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { navPath.append(ProfileRoute.settings) } label: {
                        navIconButton(icon: "line.3.horizontal")
                    }
                    .accessibilityLabel(Text("Settings", bundle: bundle))
                }
            }
            .navigationDestination(for: ProfileRoute.self) { route in
                switch route {
                case .settings:
                    SettingsView().environment(appState).environment(themeManager)
                case .privacySecurity:
                    PrivacySecurityView().environment(appState).environment(themeManager)
                case .blockedUsers:
                    BlockedUsersView().environment(appState).environment(themeManager)
                case .notificationSettings:
                    NotificationSettingsView().environment(appState).environment(themeManager)
                case .friends:
                    ConnectionsListView()
                case .followers:
                    FollowListView(userId: currentUserId, showsFollowers: true)
                case .following:
                    FollowListView(userId: currentUserId, showsFollowers: false)
                }
            }
            .sheet(isPresented: $showCreatePost) {
                CreatePostView(onPostCreated: { _ in
                    // Reload the profile after posting
                    if let userId = appState.currentUser?.id {
                        Task { await viewModel.load(userId: userId, mode: appState.currentMode.rawValue) }
                    }
                })
                .environment(appState)
            }
            .sheet(isPresented: $showEditProfile) {
                EditProfileView(onSaved: { updated in
                    viewModel.user = updated
                })
                .environment(appState)
                .environment(themeManager)
            }
            .navigationDestination(isPresented: Binding(
                get: { detailRoute != nil },
                set: { if !$0 { detailRoute = nil } }
            )) {
                if let route = detailRoute {
                    PostDetailView(postId: route.postId, focusComposer: route.focusComposer)
                }
            }
            .task {
                if let userId = appState.currentUser?.id {
                    await viewModel.load(userId: userId, mode: appState.currentMode.rawValue)
                }
                consumePendingAssistantSheet()
            }
            .onChange(of: appState.pendingAssistantSheet) { _, _ in
                consumePendingAssistantSheet()
            }
            .onChange(of: appState.currentMode) { _, newMode in
                // A new mode: start again from its side.
                showingOther = false
                otherViewModel = ProfileViewModel()
                if let userId = appState.currentUser?.id {
                    Task { await viewModel.load(userId: userId, mode: newMode.rawValue) }
                }
            }
        }
    }

    /// Opens Edit Profile when the AI assistant's "edit profile" guidance
    /// action landed here. Mirrors the consume-then-clear pattern
    /// `pendingDeepLink`/`pendingAssistantNavigation` use elsewhere.
    private func consumePendingAssistantSheet() {
        guard appState.pendingAssistantSheet == .editProfile else { return }
        appState.pendingAssistantSheet = nil
        showEditProfile = true
    }

    // MARK: Posts Section

    /// Front: edit / new post. Back: what the preview is.
    @ViewBuilder
    private var cardActions: some View {
        if showingOther {
            Label(bundle.loc(mode == .work
                    ? "This is your Work profile as others see it. Switch to Work mode to edit it."
                    : "This is your Hobby profile as others see it. Switch to Hobby mode to edit it."),
                  systemImage: mode.glyph)
                .scaledFont(13)
                .foregroundColor(AppColors.textSecondary(colorScheme))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(AppColors.elevated(colorScheme), in: RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
        } else {
            HStack(spacing: AppSpacing.sm) {
                ProfileCardButton(title: bundle.loc("Edit profile"), icon: "pencil",
                                  prominent: true) { showEditProfile = true }
                ProfileCardButton(title: bundle.loc("New post"), icon: "plus") { showCreatePost = true }
            }
        }
    }

    /// The back when you have no persona in the other mode.
    private var noOtherProfileCard: some View {
        VStack(spacing: 14) {
            Image(systemName: otherMode.glyph)
                .scaledFont(34)
                .foregroundColor(AppColors.textTertiary(colorScheme))
                .frame(width: 84, height: 84)
                .background(AppColors.elevated(colorScheme), in: Circle())
            Text(bundle.loc(otherMode == .work ? "You don't have a Work profile yet." : "You don't have a Hobby profile yet."))
                .scaledFont(16, .semibold)
                .foregroundColor(AppColors.textPrimary(colorScheme))
            Button(bundle.loc("Set it up")) { appState.requestModeSwitch(to: otherMode) }
                .scaledFont(15, .semibold)
                .foregroundColor(themeManager.theme.primary)
        }
        .padding(.vertical, 48)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .topTrailing) { FlipButton<AnyView>(flip: flipButton) }
        .background(AppColors.surface(colorScheme), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .padding(.horizontal, AppSpacing.sm)
        .padding(.top, 110)
    }

    private var postsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Posts", bundle: bundle)
                    .scaledFont(17, .semibold)
                    .foregroundColor(AppColors.textPrimary(colorScheme))
                if !shown.isLoading {
                    Text("\(shown.posts.count)")
                        .scaledFont(13, .medium)
                        .foregroundColor(AppColors.textSecondary(colorScheme))
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)

            if shown.isLoading && shown.posts.isEmpty {
                SkeletonPostList(count: 2, colorScheme: colorScheme).padding(.top, 8)
            } else if let error = shown.error, shown.posts.isEmpty {
                // A single failed load (e.g. a dropped connection) otherwise
                // left this permanently stuck empty, .task only fires once
                // per view identity, so switching tabs away and back doesn't
                // retry on its own.
                postsErrorState(error)
            } else {
                LazyVStack(spacing: AppSpacing.sm) {
                    ForEach(shown.posts) { post in
                        PostCard(
                            post: post,
                            disableSelfNavigation: true,
                            onPostDeleted: { shown.removePost(id: post.id) },
                            onPostUpdated: { updated in shown.updatePost(updated) },
                            onOpenDetail: { focus in
                                detailRoute = PostRoute(postId: post.id, focusComposer: focus)
                            }
                        )
                        .cardStyle()
                        .onAppear {
                            if post.id == shown.posts.last?.id {
                                Task {
                                    await shown.loadMorePosts(userId: currentUserId, mode: appState.currentMode.rawValue)
                                }
                            }
                        }
                    }

                    if shown.isLoadingMore {
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
                .scaledFont(32)
                .foregroundColor(AppColors.textTertiary(colorScheme))
            Text(message)
                .scaledFont(14)
                .multilineTextAlignment(.center)
                .foregroundColor(AppColors.textSecondary(colorScheme))
                .padding(.horizontal, 32)
            Button(bundle.loc("Retry")) {
                Task { await shown.load(userId: currentUserId, mode: appState.currentMode.rawValue) }
            }
            .scaledFont(14, .semibold)
            .foregroundColor(themeManager.theme.primary)
        }
        .padding(.top, 24)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
    }

    /// Bare glyph: the toolbar's Liquid Glass is its only background.
    private func navIconButton(icon: String) -> some View {
        Image(systemName: icon)
            .scaledFont(15, .medium)
            .foregroundColor(AppColors.textPrimary(colorScheme))
    }
}

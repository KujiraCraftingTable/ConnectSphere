import SwiftUI

/// Push-able destinations on `ProfileView`'s `NavigationStack`, addressable by
/// the AI assistant's navigation actions (`MainTabView
/// .consumePendingAssistantNavigation`) via the same `navPath.append`/
/// `navigationDestination(for:)` mechanism the community deep link already
/// uses. These are purely additive alongside the existing manual-tap
/// `NavigationLink`s in `SettingsView`/`PrivacySecurityView` (e.g. Blocked
/// Users is still also reachable by tapping through Privacy & Security as
/// before) — both push mechanisms coexist safely on the same stack.
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
    @Environment(\.colorScheme) var colorScheme
    @State private var showCreatePost = false
    @State private var showEditProfile = false
    // Tap-to-open-post-detail — same PostRoute/PostDetailView navigation Feed uses.
    @State private var detailRoute: PostRoute?

    /// Binding from MainTabView — resets to root whenever the tab is reselected
    @Binding var navPath: NavigationPath

    /// Only `viewModel.user` — no fallback to `appState.currentUser`, which
    /// is resolved server-side against the account's stored `default_mode`
    /// (GET /auth/me has no mode param), not the live `appState.currentMode`.
    /// Falling back to it flashed the other mode's name/bio for a moment
    /// right after switching modes. `viewModel.load()` is always in flight
    /// by the time this matters, so a brief loading state here is honest
    /// instead of showing possibly-wrong data.
    private var user: UserProfile? { viewModel.user }

    /// Used only where posts-section closures need an id while `user` may
    /// still be nil (loading) — this is always the signed-in account's own
    /// profile (ProfileViewModel is never used for anyone else's).
    private var currentUserId: String { appState.currentUser?.id ?? "" }

    var body: some View {
        NavigationStack(path: $navPath) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 8) {
                        if let user {
                            ProfileHeaderCard(user: user, mode: appState.currentMode, onStatTap: { stat in
                                switch stat {
                                case .posts:     withAnimation { proxy.scrollTo("posts", anchor: .top) }
                                case .friends:   navPath.append(ProfileRoute.friends)
                                case .followers: navPath.append(ProfileRoute.followers)
                                case .following: navPath.append(ProfileRoute.following)
                                }
                            }) {
                                HStack(spacing: AppSpacing.sm) {
                                    ProfileCardButton(title: bundle.loc("Edit profile"), icon: "pencil",
                                                      prominent: true) { showEditProfile = true }
                                    ProfileCardButton(title: bundle.loc("New post"), icon: "plus") { showCreatePost = true }
                                }
                            }
                        } else {
                            ProgressView().padding(.top, 120).frame(maxWidth: .infinity)
                        }
                        postsSection.id("posts")
                    }
                }
                // The cover runs up under the status bar; its own fade keeps
                // the clock and the floating nav button legible.
                .ignoresSafeArea(edges: .top)
                .refreshable {
                    if let userId = appState.currentUser?.id {
                        await viewModel.refresh(userId: userId, mode: appState.currentMode.rawValue)
                    }
                }
            }
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
                if let userId = appState.currentUser?.id {
                    Task { await viewModel.load(userId: userId, mode: newMode.rawValue) }
                }
            }
        }
    }

    /// Opens Edit Profile when the AI assistant's "edit profile" guidance
    /// action landed here — mirrors the consume-then-clear pattern
    /// `pendingDeepLink`/`pendingAssistantNavigation` use elsewhere.
    private func consumePendingAssistantSheet() {
        guard appState.pendingAssistantSheet == .editProfile else { return }
        appState.pendingAssistantSheet = nil
        showEditProfile = true
    }

    // MARK: Posts Section

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
                // per view identity, so switching tabs away and back doesn't
                // retry on its own.
                postsErrorState(error)
            } else {
                LazyVStack(spacing: AppSpacing.sm) {
                    ForEach(viewModel.posts) { post in
                        PostCard(
                            post: post,
                            disableSelfNavigation: true,
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
                                    await viewModel.loadMorePosts(userId: currentUserId, mode: appState.currentMode.rawValue)
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
                Task { await viewModel.load(userId: currentUserId, mode: appState.currentMode.rawValue) }
            }
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(themeManager.theme.primary)
        }
        .padding(.top, 24)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
    }

    /// Bare glyph: the toolbar's Liquid Glass is its only background.
    private func navIconButton(icon: String) -> some View {
        Image(systemName: icon)
            .font(.system(size: 15, weight: .medium))
            .foregroundColor(AppColors.textPrimary(colorScheme))
    }
}

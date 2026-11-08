import SwiftUI

struct UserProfileView: View {
    @Environment(AppState.self) var appState
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.appBundle) var bundle
    @State private var viewModel = ProfileViewModel()
    /// The person's other persona, loaded on the first flip.
    @State private var otherViewModel = ProfileViewModel()
    @State private var showingOther = false
    @State private var flipAngle: Double = 0
    @Environment(\.colorScheme) var colorScheme

    let userId: String
    let preloadedUser: UserProfile?
    /// The other side of the card (see `flip`): that mode's profile, view
    /// only, connecting happens in that mode.
    private var otherMode: AppMode { appState.currentMode == .hobby ? .work : .hobby }
    private var mode: AppMode { showingOther ? otherMode : appState.currentMode }
    /// The side being shown.
    private var shown: ProfileViewModel { showingOther ? otherViewModel : viewModel }

    /// Status bar height: the cover is pulled up under it instead of the
    /// scroll view ignoring the safe area, so the system refresh spinner shows
    /// below the Dynamic Island (as on a community page).
    @State private var topInset: CGFloat = 0
    @State private var chatConversationId: String?
    @State private var navigateToChat = false
    // Tap-to-open-post-detail, same PostRoute/PostDetailView navigation Feed uses.
    @State private var detailRoute: PostRoute?

    // Block state
    @State private var showBlockConfirm = false
    @State private var showReport = false
    /// Signed in as the official account: it bans instead of reporting or blocking.
    @State private var showBan = false
    /// Relationship (friend / request / follow) with this person. Shared by
    /// the card's buttons and the ••• menu's Follow item.
    @State private var connect = ConnectViewModel()
    @State private var listRoute: ProfileStat?

    private var isSelf: Bool { userId == appState.currentUser?.id }

    init(userId: String, preloadedUser: UserProfile? = nil) {
        self.userId = userId
        self.preloadedUser = preloadedUser
    }

    /// This mode's persona (the card's front).
    private var user: UserProfile? {
        viewModel.user ?? preloadedUser
    }

    /// Whether the person has the other persona at all.
    private var hasOther: Bool { user?.hasPersona(otherMode) ?? false }

    /// The corner button: shown unless they turned their link off.
    private var flipButton: ProfileHeaderCard<AnyView>.Flip? {
        guard !isSelf, user?.linksOtherMode ?? false else { return nil }
        return .init(to: showingOther ? appState.currentMode : otherMode) { flip() }
    }

    /// Turns the card edge-on, swaps the side, turns it back.
    private func flip() {
        Task {
            withAnimation(.easeIn(duration: 0.18)) { flipAngle = 90 }
            try? await Task.sleep(for: .milliseconds(180))
            showingOther.toggle()
            flipAngle = -90
            withAnimation(.easeOut(duration: 0.22)) { flipAngle = 0 }
            if showingOther, hasOther, otherViewModel.user == nil {
                await otherViewModel.load(userId: userId, mode: otherMode.rawValue)
            }
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Group {
                if let front = user {
                    VStack(spacing: 8) {
                        if showingOther && !hasOther {
                            noOtherProfileCard(front)
                                .rotation3DEffect(.degrees(flipAngle), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
                        } else if let user = showingOther ? otherViewModel.user : front {
                            ProfileHeaderCard(user: user, mode: mode, onStatTap: { stat in
                                if stat == .posts { withAnimation { proxy.scrollTo("posts", anchor: .top) } }
                                // The lists are your own mode's; not from the other persona.
                                else if !showingOther { listRoute = stat }
                            }, flip: flipButton) {
                                AnyView(actions(for: user))
                            }
                            .rotation3DEffect(.degrees(flipAngle), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
                            // The official account keeps no about, education, work or skills.
                            // Locked out, the About parts stay; Highlights and posts don't.
                            if mode == .hobby && !user.isOfficial {
                                HobbyAboutSection(user: user, isMe: user.id == appState.currentUser?.id)
                                if !user.lockedOut {
                                    HighlightsRow(userId: user.id, isMe: user.id == appState.currentUser?.id)
                                }
                            }
                            if mode == .work && !user.isOfficial {
                                ExperienceSection(userId: user.id, isMe: user.id == appState.currentUser?.id)
                                SkillsSection(userId: user.id, isMe: user.id == appState.currentUser?.id,
                                              allowsEndorsing: !showingOther)
                            }
                            if user.lockedOut { lockedPostsNote(user) } else { postsSection.id("posts") }
                        } else {
                            ProgressView().padding(.top, 120)
                        }
                    }
                } else {
                    ProgressView().padding(.top, 120)
                }
                }
                // The cover runs up under the status bar; its fade keeps it legible.
                .padding(.top, -topInset)
            }
            .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.top } action: { topInset = $0 }
            .refreshable {
                await viewModel.refresh(userId: userId, mode: mode.rawValue)
                if userId != appState.currentUser?.id { await viewModel.loadBlockStatus(userId: userId) }
            }
        }
        .background(AppColors.base(colorScheme))
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        // Someone's profile is a page of its own: no tab bar, like a chat.
        .toolbar(.hidden, for: .tabBar)
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
                        if !viewModel.isBlocked && !showingOther && !(appState.currentUser?.isOfficial ?? false) {
                            Button {
                                Task { await connect.setFollowing(!connect.isFollowing, targetId: userId,
                                                                  mode: mode.rawValue) }
                            } label: {
                                Label(bundle.loc(connect.isFollowing ? "Unfollow" : "Follow"),
                                      systemImage: connect.isFollowing ? "person.crop.circle.badge.xmark"
                                                                       : "person.crop.circle.badge.plus")
                            }
                        }
                        if appState.currentUser?.isOfficial ?? false {
                            // The admin doesn't report or block: it bans, through a case.
                            Button(role: .destructive) { showBan = true } label: {
                                Label(bundle.loc("Warn or ban"), systemImage: "hand.raised.slash")
                            }
                        } else if !(user?.isOfficial ?? false) {
                            // The official account can't be reported or blocked (the server refuses too).
                            Button {
                                showReport = true
                            } label: {
                                Label(bundle.loc("Report profile"), systemImage: "flag")
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
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .scaledFont(16, .semibold)
                            .foregroundColor(AppColors.textPrimary(colorScheme))
                    }
                }
            }
        }
        .sheet(isPresented: $showBan) {
            // The persona being looked at: bans and warnings are per mode.
            AdminBanSheet(target: ModerationTarget(type: "user", id: userId, userId: userId,
                                                   userName: user?.name ?? "", mode: mode.rawValue))
                .environment(themeManager)
        }
        .sheet(isPresented: $showReport) {
            // The profile of the mode being looked at — Hobby and Work are reported apart.
            ReportSheet(subject: .content(.user, id: userId, mode: mode.rawValue))
                .environment(themeManager)
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
        // Follow/Unfollow on this profile moves the follower count right away.
        .onChange(of: connect.followDelta) { old, new in viewModel.adjustFollowerCount(by: new - old) }
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
            // Your mode changed: start again from this mode's side.
            showingOther = false
            otherViewModel = ProfileViewModel()
            Task { await viewModel.load(userId: userId, mode: newMode.rawValue) }
        }
    }

    // MARK: Card buttons

    @ViewBuilder
    private func actions(for user: UserProfile) -> some View {
        if isSelf {
            EmptyView()
        } else if showingOther {
            // View only: connecting / messaging happens in that mode.
            Label(String(format: bundle.loc(mode == .work
                    ? "You're viewing %@'s Work profile. Switch to Work mode to connect."
                    : "You're viewing %@'s Hobby profile. Switch to Hobby mode to connect."), user.name),
                  systemImage: mode.glyph)
                .scaledFont(13)
                .foregroundColor(AppColors.textSecondary(colorScheme))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(AppColors.elevated(colorScheme),
                            in: RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
        } else if viewModel.isBlocked {
            // Blocked → can no longer connect with or message this person.
            Text("Blocked", bundle: bundle)
                .scaledFont(13, .semibold)
                .foregroundColor(AppColors.danger(colorScheme))
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(AppColors.danger(colorScheme).opacity(0.12),
                            in: RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
        } else {
            ProfileActionBar(targetUserId: userId, targetName: user.name, connect: connect,
                             isOpeningChat: viewModel.isOpeningChat, targetIsOfficial: user.isOfficial) { openChat() }
        }
    }

    /// The other side when there's no persona there.
    private func noOtherProfileCard(_ front: UserProfile) -> some View {
        VStack(spacing: 14) {
            Image(systemName: otherMode.glyph)
                .scaledFont(34)
                .foregroundColor(AppColors.textTertiary(colorScheme))
                .frame(width: 84, height: 84)
                .background(AppColors.elevated(colorScheme), in: Circle())
            Text(String(format: bundle.loc(otherMode == .work
                    ? "%@ doesn't have a profile in Work mode."
                    : "%@ doesn't have a profile in Hobby mode."), front.name))
                .scaledFont(16, .semibold)
                .foregroundColor(AppColors.textPrimary(colorScheme))
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 48)
        .padding(.horizontal, AppSpacing.lg)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .topTrailing) {
            if let flipButton { FlipButton<AnyView>(flip: flipButton) }
        }
        .background(AppColors.surface(colorScheme), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .padding(.horizontal, AppSpacing.sm)
        .padding(.top, 110)
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

    /// In place of the posts for someone outside a locked persona.
    private func lockedPostsNote(_ user: UserProfile) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "lock.shield.fill")
                .scaledFont(28)
                .foregroundColor(AppColors.textSecondary(colorScheme))
            Text("This profile is locked", bundle: bundle)
                .scaledFont(16, .semibold)
                .foregroundColor(AppColors.textPrimary(colorScheme))
            Text(String(format: bundle.loc(mode == .work
                    ? "Connect with %@ to see their posts."
                    : "Add %@ as a friend to see their posts."), user.name))
                .scaledFont(14)
                .foregroundColor(AppColors.textSecondary(colorScheme))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .cardStyle()
        .padding(.horizontal, AppSpacing.sm)
        .padding(.bottom, 16)
    }

    @ViewBuilder
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
                ProgressView().padding(.top, 20).frame(maxWidth: .infinity)
            } else if let error = shown.error, shown.posts.isEmpty {
                // A single failed load (e.g. a dropped connection) otherwise
                // left this permanently stuck empty, .task only fires once
                // per view identity, so navigating away and back doesn't
                // retry on its own.
                postsErrorState(error)
            } else {
                LazyVStack(spacing: AppSpacing.sm) {
                    ForEach(shown.posts) { post in
                        PostCard(
                            post: post,
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
                                    await shown.loadMorePosts(userId: userId, mode: mode.rawValue)
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
                Task { await shown.load(userId: userId, mode: mode.rawValue) }
            }
            .scaledFont(14, .semibold)
            .foregroundColor(themeManager.theme.primary)
        }
        .padding(.top, 24)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
    }
}

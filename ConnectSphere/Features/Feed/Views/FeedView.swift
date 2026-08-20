import SwiftUI

struct FeedView: View {
    @Environment(AppState.self) var appState
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.appBundle) var bundle
    @State private var viewModel = FeedViewModel()
    @Environment(\.colorScheme) var colorScheme
    @State private var showCreatePost = false
    @State private var showMessages = false
    @Binding var selectedTab: Int

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 5) {
                    Color.clear.frame(height: 0).id("feedTop")
                    createPostBar
                        .background(AppColors.surface(colorScheme))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.25 : 0.06),
                                radius: 4, x: 0, y: 2)

                    if appState.currentMode == .hobby {
                        StoriesRow()
                            .background(AppColors.surface(colorScheme))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.25 : 0.06),
                                    radius: 4, x: 0, y: 2)
                    }

                    feedScopeRow

                    if viewModel.isLoading && viewModel.posts(for: appState.currentMode).isEmpty {
                        ProgressView()
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
                                onPostUpdated: { updated in viewModel.updatePost(updated) }
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.25 : 0.06),
                                    radius: 4, x: 0, y: 2)
                            .onAppear {
                                // Cuộn tới bài cuối → tải trang tiếp theo
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
                .padding(.horizontal, 10)
                .padding(.bottom, 16)
            }
            .background(AppColors.base(colorScheme))
            .navigationBarTitleDisplayMode(.inline)
            .task {
                await viewModel.loadPostsIfNeeded(for: appState.currentMode)
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
            }
            .onChange(of: viewModel.feedScope) { _, _ in
                withAnimation(.easeInOut(duration: 0.4)) {
                    proxy.scrollTo("feedTop", anchor: .top)
                }
                Task {
                    await viewModel.loadPosts(for: appState.currentMode)
                }
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
            .sheet(isPresented: $showCreatePost) {
                CreatePostView(onPostCreated: {
                    Task { await viewModel.loadPosts(for: appState.currentMode) }
                })
                .environment(appState)
            }
            .navigationDestination(isPresented: $showMessages) {
                ConversationListView()
            }
            .onAppear {
                setupChatBadge()
            }
            .onDisappear {
                WebSocketClient.shared.off("new_message", tag: "feedBadge")
            }
        }
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

    // MARK: Mode Switch Pill (center of nav bar)

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
                // Chưa setup persona của mode đích → AppState hiện form tạo trước
                appState.requestModeSwitch(to: mode)
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 11, weight: .semibold))
                Text(label).font(.system(size: 12, weight: .semibold))
            }
            .foregroundColor(isActive ? .white : AppColors.textSecondary(colorScheme))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(isActive ? themeManager.theme.primary : Color.clear, in: Capsule())
        }
        .buttonStyle(.plain)
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
            AvatarView(user: appState.currentUser ?? MockData.currentUser, size: 40)

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
                if appState.chatUnreadCount > 0 {
                    Text(appState.chatUnreadCount > 99 ? "99+" : "\(appState.chatUnreadCount)")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.red))
                        .offset(x: 4, y: -4)
                }
            }
        }
    }
}

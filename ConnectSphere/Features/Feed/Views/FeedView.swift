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

                    if appState.currentMode == .friend {
                        StoriesRow()
                            .background(AppColors.surface(colorScheme))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.25 : 0.06),
                                    radius: 4, x: 0, y: 2)
                    }

                    feedScopePicker

                    if viewModel.isLoading && viewModel.posts(for: appState.currentMode).isEmpty {
                        ProgressView()
                            .padding(.top, 40)
                    } else if viewModel.posts(for: appState.currentMode).isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "person.2")
                                .font(.system(size: 36))
                                .foregroundColor(AppColors.textSecondary(colorScheme).opacity(0.4))
                            Text(viewModel.feedScope == .connections
                                 ? bundle.loc("Chưa có bài viết từ kết nối của bạn")
                                 : bundle.loc("Chưa có bài viết nào"))
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
            } // ScrollViewReader
            .toolbar {
                ToolbarItem(placement: .principal) {
                    modeSwitchPill
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 6) {
                        chatIconButton
                        navIconButton(icon: "magnifyingglass")
                    }
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

    // MARK: Feed scope picker (Tất cả / Kết nối)

    private var feedScopePicker: some View {
        HStack(spacing: 8) {
            scopeChip(label: bundle.loc("Tất cả"), scope: .all)
            scopeChip(label: bundle.loc("Kết nối"), scope: .connections)
            Spacer()
        }
        .padding(.horizontal, 4)
        .padding(.top, 2)
    }

    private func scopeChip(label: String, scope: FeedScope) -> some View {
        let isSelected = viewModel.feedScope == scope
        return Button {
            Task { await viewModel.switchScope(scope, mode: appState.currentMode) }
        } label: {
            Text(label)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(isSelected ? .white : AppColors.textSecondary(colorScheme))
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(
                    Capsule().fill(
                        isSelected
                            ? AnyShapeStyle(themeManager.theme.primary)
                            : AnyShapeStyle(AppColors.surface(colorScheme))
                    )
                )
        }
        .buttonStyle(.plain)
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
            modePillButton(mode: .friend, icon: "person.2.fill", label: bundle.loc("Bạn bè"))
            modePillButton(mode: .colleague, icon: "briefcase.fill", label: bundle.loc("Công việc"))
        }
        .background(AppColors.surface(colorScheme), in: Capsule())
        .padding(.vertical, 4)
    }

    private func modePillButton(mode: AppMode, icon: String, label: String) -> some View {
        let isActive = appState.currentMode == mode
        return Button {
            withAnimation(.spring(response: 0.3)) {
                appState.currentMode = mode
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

    // MARK: Create Post Bar

    private var createPostBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                AvatarView(user: appState.currentUser ?? MockData.currentUser, size: 40)

                Button { showCreatePost = true } label: {
                    Text(appState.currentMode == .friend
                         ? bundle.loc("Bạn đang nghĩ gì vậy?")
                         : bundle.loc("Chia sẻ cập nhật chuyên nghiệp..."))
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
            .padding(.top, 10)
            .padding(.bottom, 8)

            Divider()

            HStack(spacing: 0) {
                postTypeButton(icon: "video.fill", label: bundle.loc("Trực tiếp"), color: Color(hex: "#F02849"))
                postTypeButton(icon: "photo.fill", label: bundle.loc("Ảnh"), color: Color(hex: "#45BD62"))
                postTypeButton(
                    icon: appState.currentMode == .friend ? "face.smiling" : "doc.text.fill",
                    label: appState.currentMode == .friend ? bundle.loc("Cảm xúc") : bundle.loc("Bài viết"),
                    color: Color(hex: "#F7B928")
                )
            }
            .padding(.bottom, 6)
        }
    }

    private func postTypeButton(icon: String, label: String, color: Color) -> some View {
        Button {} label: {
            HStack(spacing: 6) {
                Image(systemName: icon).foregroundColor(color).font(.system(size: 16))
                Text(label).font(.system(size: 14, weight: .medium)).foregroundColor(AppColors.textSecondary(colorScheme))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
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

    private func navIconButton(icon: String) -> some View {
        Button {
            if icon == "magnifyingglass" {
                selectedTab = 1
                appState.shouldFocusSearch = true
            }
        } label: {
            ZStack {
                Circle().fill(AppColors.elevated(colorScheme)).frame(width: 36, height: 36)
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(AppColors.textPrimary(colorScheme))
            }
        }
    }
}

import SwiftUI

struct UserProfileView: View {
    @Environment(AppState.self) var appState
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.appBundle) var bundle
    @State private var viewModel = ProfileViewModel()
    @Environment(\.colorScheme) var colorScheme

    let userId: String
    let preloadedUser: UserProfile?

    @State private var chatConversationId: String?
    @State private var navigateToChat = false
    // Tap-to-open-post-detail — same PostRoute/PostDetailView navigation Feed uses.
    @State private var detailRoute: PostRoute?

    // Block state
    @State private var showBlockConfirm = false

    init(userId: String, preloadedUser: UserProfile? = nil) {
        self.userId = userId
        self.preloadedUser = preloadedUser
    }

    private var user: UserProfile? {
        viewModel.user ?? preloadedUser
    }

    var body: some View {
        ScrollView {
            if let user = user {
                VStack(spacing: 8) {
                    profileHeader(user: user)
                    statsRow(user: user)
                    infoSection(user: user)
                    postsSection
                }
            } else {
                ProgressView().padding(.top, 60)
            }
        }
        .background(AppColors.base(colorScheme))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if userId != appState.currentUser?.id {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
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
        .confirmationDialog(
            bundle.loc("Block this user?"),
            isPresented: $showBlockConfirm,
            titleVisibility: .visible
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
            await viewModel.load(userId: userId, mode: appState.currentMode.rawValue)
            if userId != appState.currentUser?.id {
                await viewModel.loadBlockStatus(userId: userId)
            }
        }
        .onChange(of: appState.currentMode) { _, newMode in
            Task { await viewModel.load(userId: userId, mode: newMode.rawValue) }
        }
    }

    // MARK: Header

    private func profileHeader(user: UserProfile) -> some View {
        ZStack(alignment: .bottomLeading) {
            CoverPhotoView(coverUrl: user.coverUrl)

            HStack(alignment: .bottom) {
                AvatarView(user: user, size: 90)
                    .overlay(Circle().stroke(Color.white, lineWidth: 4))
                    .offset(y: 45)
                    .padding(.leading, 16)
                Spacer()
                if userId != appState.currentUser?.id {
                    Group {
                        if viewModel.isBlocked {
                            // Blocked → can no longer connect/message this user
                            Text("Blocked", bundle: bundle)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.red)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Capsule().fill(Color.red.opacity(0.12)))
                        } else {
                            // The companion (Message button) wraps to its own row below
                            // when Accept + Decline both need to be shown at the same time.
                            ConnectButton(targetUserId: userId) { AnyView(messageButton) }
                        }
                    }
                    .padding(.trailing, 16)
                    .padding(.bottom, 12)
                }
            }
        }
        .padding(.bottom, 50)
        .background(AppColors.surface(colorScheme))
    }

    // MARK: Stats

    private func statsRow(user: UserProfile) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(user.name)
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(AppColors.textPrimary(colorScheme))

            if let title = user.jobTitle, let company = user.company {
                Text("\(title) · \(company)")
                    .font(.system(size: 15))
                    .foregroundColor(AppColors.textSecondary(colorScheme))
            }

            if !user.bio.isEmpty {
                Text(user.bio)
                    .font(.system(size: 14))
                    .foregroundColor(AppColors.textSecondary(colorScheme))
            }

            if let location = user.location {
                HStack(spacing: 4) {
                    Image(systemName: "mappin.circle.fill")
                        .font(.system(size: 13))
                    Text(location)
                        .font(.system(size: 13))
                }
                .foregroundColor(AppColors.textSecondary(colorScheme))
            }

            HStack(spacing: 20) {
                statItem(count: user.postCount, label: bundle.loc("Posts"))
                statItem(count: user.connectionCount,
                         label: appState.currentMode == .hobby
                             ? bundle.loc("Friends") : bundle.loc("Connections"))
                Spacer()
            }
            .padding(.top, 4)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(AppColors.surface(colorScheme))
    }

    private func statItem(count: Int, label: String) -> some View {
        VStack(spacing: 1) {
            Text("\(count)")
                .font(.system(size: 17, weight: .bold))
                .foregroundColor(AppColors.textPrimary(colorScheme))
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(AppColors.textSecondary(colorScheme))
        }
    }

    // MARK: Info

    @ViewBuilder
    private func infoSection(user: UserProfile) -> some View {
        if !user.skills.isEmpty {
            chipSection(title: bundle.loc("Skills"), items: user.skills)
        }
        if !user.interests.isEmpty {
            chipSection(title: bundle.loc("Interests"), items: user.interests)
        }
    }

    private func chipSection(title: String, items: [String]) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Text(title)
                .appFont(.headline)
                .foregroundColor(AppColors.textPrimary(colorScheme))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: AppSpacing.sm) {
                    ForEach(items, id: \.self) { item in
                        Chip(text: item, style: .neutral)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AppSpacing.lg)
        .background(AppColors.surface(colorScheme))
    }

    // MARK: Message button

    private var messageButton: some View {
        Button {
            Task {
                guard let convId = await viewModel.openConversation(
                    with: userId, mode: appState.currentMode, token: appState.authToken) else { return }
                chatConversationId = convId
                navigateToChat = true
            }
        } label: {
            HStack(spacing: 4) {
                if viewModel.isOpeningChat {
                    ProgressView().scaleEffect(0.7).tint(.white)
                } else {
                    Image(systemName: "message.fill")
                        .font(.system(size: 11, weight: .semibold))
                }
                Text("Message", bundle: bundle)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .fixedSize()
            }
            .foregroundColor(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Capsule().fill(themeManager.theme.primary))
        }
        .buttonStyle(.plain)
        .disabled(viewModel.isOpeningChat)
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
                                    await viewModel.loadMorePosts(userId: userId, mode: appState.currentMode.rawValue)
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
                Task { await viewModel.load(userId: userId, mode: appState.currentMode.rawValue) }
            }
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(themeManager.theme.primary)
        }
        .padding(.top, 24)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
    }
}

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
    @State private var isOpeningChat = false

    // Block state
    @State private var isBlocked = false
    @State private var showBlockConfirm = false
    private let userRepo = UserRepository()

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
                        if isBlocked {
                            Button {
                                Task { await toggleBlock() }
                            } label: {
                                Label(bundle.loc("Bỏ chặn"), systemImage: "person.crop.circle.badge.checkmark")
                            }
                        } else {
                            Button(role: .destructive) {
                                showBlockConfirm = true
                            } label: {
                                Label(bundle.loc("Chặn người dùng"), systemImage: "nosign")
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
            bundle.loc("Chặn người dùng này?"),
            isPresented: $showBlockConfirm,
            titleVisibility: .visible
        ) {
            Button(bundle.loc("Chặn"), role: .destructive) {
                Task { await toggleBlock() }
            }
            Button(bundle.loc("Huỷ"), role: .cancel) {}
        } message: {
            Text("Hai bạn sẽ không còn thấy bài viết của nhau, mọi kết nối sẽ bị gỡ và không thể nhắn tin cho nhau.", bundle: bundle)
        }
        .navigationDestination(isPresented: $navigateToChat) {
            if let convId = chatConversationId, let user = user {
                ChatView(
                    conversationId: convId,
                    otherUserId: userId,
                    otherUserName: user.name,
                    otherUserAvatarColor: user.avatarColor,
                    otherUserLocation: user.location,
                    currentUserId: appState.currentUser?.id ?? "",
                    token: appState.authToken ?? ""
                )
            }
        }
        .task {
            await viewModel.load(userId: userId)
            if userId != appState.currentUser?.id {
                isBlocked = (try? await userRepo.fetchBlockStatus(userId: userId)) ?? false
            }
        }
    }

    /// Chặn / bỏ chặn user đang xem
    private func toggleBlock() async {
        do {
            if isBlocked {
                try await userRepo.unblockUser(userId: userId)
                isBlocked = false
            } else {
                try await userRepo.blockUser(userId: userId)
                isBlocked = true
            }
        } catch {
            // Giữ nguyên trạng thái; user có thể thử lại từ menu
        }
    }

    // MARK: Header

    private func profileHeader(user: UserProfile) -> some View {
        ZStack(alignment: .bottomLeading) {
            Rectangle()
                .fill(LinearGradient(
                    colors: [themeManager.theme.primary.opacity(0.6), themeManager.theme.primary.opacity(0.2)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ))
                .frame(height: 160)

            HStack(alignment: .bottom) {
                AvatarView(user: user, size: 90)
                    .overlay(Circle().stroke(Color.white, lineWidth: 4))
                    .offset(y: 45)
                    .padding(.leading, 16)
                Spacer()
                if userId != appState.currentUser?.id {
                    HStack(spacing: 8) {
                        if isBlocked {
                            // Đã chặn → không kết nối/nhắn tin được nữa
                            Text("Đã chặn", bundle: bundle)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.red)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Capsule().fill(Color.red.opacity(0.12)))
                        } else {
                            ConnectButton(targetUserId: userId)
                            messageButton
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
                statItem(count: user.postCount,      label: bundle.loc("Bài viết"))
                statItem(count: user.followerCount,  label: bundle.loc("Người theo dõi"))
                statItem(count: user.followingCount, label: bundle.loc("Đang theo dõi"))
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
            chipSection(title: bundle.loc("Kỹ năng"), items: user.skills)
        }
        if !user.interests.isEmpty {
            chipSection(title: bundle.loc("Sở thích"), items: user.interests)
        }
    }

    private func chipSection(title: String, items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(AppColors.textPrimary(colorScheme))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(items, id: \.self) { item in
                        Text(item)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(themeManager.theme.primary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(themeManager.theme.primary.opacity(0.1)))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(AppColors.surface(colorScheme))
    }

    // MARK: Message button

    private var messageButton: some View {
        Button {
            Task { await openChat() }
        } label: {
            HStack(spacing: 4) {
                if isOpeningChat {
                    ProgressView().scaleEffect(0.7).tint(.white)
                } else {
                    Image(systemName: "message.fill")
                        .font(.system(size: 11, weight: .semibold))
                }
                Text("Nhắn tin", bundle: bundle)
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Capsule().fill(themeManager.theme.primary))
        }
        .buttonStyle(.plain)
        .disabled(isOpeningChat)
    }

    private func openChat() async {
        guard let token = appState.authToken else { return }
        isOpeningChat = true
        defer { isOpeningChat = false }
        do {
            let convId = try await MessageRepository().openConversation(
                otherUserId: userId,
                mode: appState.currentMode.rawValue,
                token: token
            )
            chatConversationId = convId
            navigateToChat = true
        } catch {
            // silently fail — user can retry
        }
    }

    // MARK: Posts

    @ViewBuilder
    private var postsSection: some View {
        let posts = Array(viewModel.posts
            .filter { $0.mode == appState.currentMode }
            .prefix(5))

        VStack(alignment: .leading, spacing: 8) {
            // Label kiểu Fandom — floating trên nền xám
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Bài viết", bundle: bundle)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(AppColors.textPrimary(colorScheme))
                if !viewModel.isLoading {
                    Text("\(posts.count)")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(AppColors.textSecondary(colorScheme))
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)

            if viewModel.isLoading && viewModel.posts.isEmpty {
                ProgressView().padding(.top, 20).frame(maxWidth: .infinity)
            } else {
                VStack(spacing: 5) {
                    ForEach(posts) { post in
                        PostCard(
                            post: post,
                            onPostDeleted: { viewModel.removePost(id: post.id) },
                            onPostUpdated: { updated in viewModel.updatePost(updated) }
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.25 : 0.06),
                                radius: 4, x: 0, y: 2)
                        .padding(.horizontal, 10)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 16)
    }
}

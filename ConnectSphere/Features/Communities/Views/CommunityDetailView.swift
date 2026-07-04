import SwiftUI

struct CommunityDetailView: View {
    @Environment(AppState.self) var appState
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.appBundle) var bundle
    @State private var viewModel: CommunityDetailViewModel
    @State private var selectedTab = 0
    @State private var showCreatePost = false
    @State private var showJoinRequests  = false
    @State private var showModeration    = false
    @State private var showAnalytics     = false
    @State private var reportTargetId: String? = nil
    @State private var showReportMember  = false

    let communityId: String

    init(communityId: String, token: String) {
        self.communityId = communityId
        _viewModel = State(initialValue: CommunityDetailViewModel(
            communityId: communityId, token: token
        ))
    }

    // MARK: - Computed helpers

    private var accentColor: Color {
        Color(hex: viewModel.community?.coverColor ?? "#7F5AF0")
    }

    private var currentUserRole: MemberRole? {
        viewModel.community?.role
    }

    private var isStaff: Bool {
        currentUserRole == .admin || currentUserRole == .moderator
    }

    // MARK: - Body

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                communityHeader

                Section(header: tabBar) {
                    if selectedTab == 0 {
                        feedContent
                    } else {
                        membersContent
                    }
                }
            }
        }
        .appBackground()
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isStaff {
                // Moderation queue (admin/mod)
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showModeration = true } label: {
                        Image(systemName: "shield.lefthalf.filled")
                            .font(.system(size: 17))
                    }
                }
                // Join-request button (admin/mod, private communities only)
                if viewModel.community?.privacy == .private {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button { showJoinRequests = true } label: {
                            Image(systemName: "person.badge.plus")
                                .font(.system(size: 17))
                        }
                    }
                }
            }
            // Analytics (admin only)
            if currentUserRole == .admin {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showAnalytics = true } label: {
                        Image(systemName: "chart.xyaxis.line")
                            .font(.system(size: 17))
                    }
                }
            }
        }
        .task { await viewModel.fetchAll() }
        .refreshable { await viewModel.fetchPosts(reset: true) }
        .overlay(alignment: .bottomTrailing) {
            if viewModel.community?.isMember == true {
                createPostFAB
            }
        }
        .sheet(isPresented: $showCreatePost) {
            if let community = viewModel.community {
                CommunityCreatePostView(community: community) { post in
                    viewModel.prependPost(post)
                }
                .environment(appState)
            }
        }
        .navigationDestination(isPresented: $showJoinRequests) {
            JoinRequestsView(
                communityId: viewModel.community?.id ?? "",
                token: appState.authToken ?? ""
            )
        }
        .navigationDestination(isPresented: $showModeration) {
            ModerationQueueView(
                communityId: viewModel.community?.id ?? "",
                token:       appState.authToken ?? "",
                coverColor:  viewModel.community?.coverColor ?? "#7F5AF0"
            )
        }
        .navigationDestination(isPresented: $showAnalytics) {
            CommunityAnalyticsView(
                communityId: viewModel.community?.id ?? "",
                token:       appState.authToken ?? "",
                coverColor:  viewModel.community?.coverColor ?? "#7F5AF0"
            )
        }
        .sheet(isPresented: $showReportMember) {
            if let memberId = reportTargetId {
                ReportSheet(
                    targetType:  "member",
                    targetId:    memberId,
                    communityId: viewModel.community?.id ?? "",
                    token:       appState.authToken ?? ""
                )
            }
        }
        .alert(bundle.loc("Lỗi"), isPresented: .constant(viewModel.errorMessage != nil)) {
            Button(bundle.loc("OK")) { viewModel.errorMessage = nil }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
    }

    // MARK: - Header

    private var communityHeader: some View {
        ZStack(alignment: .bottomLeading) {
            Rectangle()
                .fill(accentColor.gradient)
                .frame(height: 130)

            HStack(alignment: .bottom, spacing: 12) {
                Text(viewModel.community?.iconEmoji ?? "👥")
                    .font(.system(size: 48))
                    .padding(.leading, 16)
                    .padding(.bottom, 12)

                VStack(alignment: .leading, spacing: 2) {
                    Text(viewModel.community?.name ?? "")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(.white)
                    if let count = viewModel.community?.memberCount {
                        Text(String(format: bundle.loc("%lld thành viên"), count))
                            .font(.system(size: 13))
                            .foregroundColor(.white.opacity(0.8))
                    }
                }
                .padding(.bottom, 14)
                Spacer()

                // Join / Request / Pending button for non-members
                if viewModel.community?.isMember == false {
                    joinButton
                        .padding(.trailing, 16)
                        .padding(.bottom, 12)
                }
            }
        }
    }

    @ViewBuilder
    private var joinButton: some View {
        switch viewModel.joinStatus {
        case .notMember:
            Button {
                Task<Void, Never>(name: nil) { await viewModel.requestToJoin() }
            } label: {
                joinButtonLabel(
                    title: viewModel.community?.privacy == .private ? bundle.loc("Yêu cầu tham gia") : bundle.loc("Tham gia"),
                    bg: .white, fg: accentColor
                )
            }
            .buttonStyle(.plain)

        case .loading:
            ProgressView()
                .tint(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

        case .pending:
            joinButtonLabel(title: bundle.loc("Đang chờ"), bg: .white.opacity(0.3), fg: .white)
                .disabled(true)

        case .joined:
            EmptyView()
        }
    }

    private func joinButtonLabel(title: String, bg: Color, fg: Color) -> some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(fg)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(bg)
            .clipShape(Capsule())
    }

    // MARK: - Tab bar

    private var tabBar: some View {
        HStack(spacing: 0) {
            tabButton(title: bundle.loc("Bảng tin"),   index: 0)
            tabButton(title: bundle.loc("Thành viên"), index: 1)
        }
        .background(AppColors.surface(colorScheme))
        .overlay(alignment: .bottom) {
            Divider().background(AppColors.borderSubtle(colorScheme))
        }
    }

    private func tabButton(title: String, index: Int) -> some View {
        Button {
            selectedTab = index
        } label: {
            VStack(spacing: 0) {
                Text(title)
                    .font(.system(size: 15, weight: selectedTab == index ? .semibold : .regular))
                    .foregroundColor(selectedTab == index
                        ? AppColors.textPrimary(colorScheme)
                        : AppColors.textSecondary(colorScheme))
                    .padding(.vertical, 12)

                Rectangle()
                    .fill(selectedTab == index ? accentColor : Color.clear)
                    .frame(height: 2)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Feed

    @ViewBuilder
    private var feedContent: some View {
        if viewModel.isLoadingPosts && viewModel.posts.isEmpty {
            ProgressView()
                .padding(.top, 40)
                .frame(maxWidth: .infinity)
        } else if viewModel.posts.isEmpty {
            emptyFeed
        } else {
            LazyVStack(spacing: 8) {
                ForEach(viewModel.posts) { post in
                    CommunityPostCard(
                        post:              post,
                        currentUserId:     appState.currentUser?.id ?? "",
                        communityId:       communityId,
                        token:             appState.authToken ?? "",
                        accentColor:       accentColor,
                        currentUserRole:   currentUserRole,
                        onDelete: {
                            Task<Void, Never>(name: nil) { await deletePost(post) }
                        },
                        onPin: isStaff ? {
                            Task<Void, Never>(name: nil) { await viewModel.pinPost(post.id) }
                        } : nil,
                        onUnpin: isStaff ? {
                            Task<Void, Never>(name: nil) { await viewModel.unpinPost(post.id) }
                        } : nil
                    )
                    .padding(.horizontal, 10)
                    .task { await viewModel.loadMorePostsIfNeeded(currentPost: post) }
                }
                if viewModel.isLoadingPosts {
                    ProgressView().padding(.vertical, 12)
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 80)
        }
    }

    private var emptyFeed: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.text")
                .font(.system(size: 40))
                .foregroundColor(AppColors.textTertiary(colorScheme))
            Text("Chưa có bài viết nào", bundle: bundle)
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(AppColors.textSecondary(colorScheme))
            if viewModel.community?.isMember == true {
                Text("Hãy là người đầu tiên đăng bài trong cộng đồng này!", bundle: bundle)
                    .font(.system(size: 14))
                    .foregroundColor(AppColors.textTertiary(colorScheme))
            }
        }
        .padding(.top, 60)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Members

    @ViewBuilder
    private var membersContent: some View {
        if viewModel.isLoadingMembers {
            ProgressView().padding(.top, 40).frame(maxWidth: .infinity)
        } else {
            LazyVStack(spacing: 0) {
                ForEach(viewModel.members) { member in
                    memberRow(member)
                    Divider()
                        .background(AppColors.borderSubtle(colorScheme))
                        .padding(.leading, 60)
                }
            }
            .surfaceBackground()
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .padding(10)
        }
    }

    private func memberRow(_ member: CommunityMember) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(Color(hex: member.avatarColor))
                Text(String(member.displayName.prefix(1)))
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.white)
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(member.displayName)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(AppColors.textPrimary(colorScheme))
                Text("@\(member.username)")
                    .font(.system(size: 13))
                    .foregroundColor(AppColors.textSecondary(colorScheme))
            }
            Spacer()
            if member.role != .member {
                Text(member.role.label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(accentColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(accentColor.opacity(0.12))
                    .clipShape(Capsule())
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contextMenu { memberContextMenu(member) }
    }

    @ViewBuilder
    private func memberContextMenu(_ member: CommunityMember) -> some View {
        let isSelf  = member.id == (appState.currentUser?.id ?? "")
        let canKick = currentUserRole == .admin
                   || (currentUserRole == .moderator && member.role == .member)

        // Staff actions (not on self)
        if isStaff && !isSelf {
            // Role change — admin only
            if currentUserRole == .admin && member.role == .member {
                Button {
                    Task<Void, Never>(name: nil) { await viewModel.updateRole(userId: member.id, newRole: .moderator) }
                } label: {
                    Label(bundle.loc("Phong Điều hành viên"), systemImage: "person.badge.shield.checkmark")
                }
            }
            if currentUserRole == .admin && member.role == .moderator {
                Button {
                    Task<Void, Never>(name: nil) { await viewModel.updateRole(userId: member.id, newRole: .member) }
                } label: {
                    Label(bundle.loc("Xóa Điều hành viên"), systemImage: "person.badge.minus")
                }
            }

            // Kick
            if canKick {
                Divider()
                Button(role: .destructive) {
                    Task<Void, Never>(name: nil) { await viewModel.kickMember(member.id) }
                } label: {
                    Label(bundle.loc("Xóa khỏi cộng đồng"), systemImage: "person.crop.circle.badge.xmark")
                }
            }
        }

        // Report — any member can report another member (not self)
        if !isSelf {
            Divider()
            Button {
                reportTargetId  = member.id
                showReportMember = true
            } label: {
                Label("Báo cáo thành viên này", systemImage: "flag")
            }
        }
    }

    // MARK: - FAB

    private var createPostFAB: some View {
        Button { showCreatePost = true } label: {
            Image(systemName: "plus")
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 54, height: 54)
                .background(accentColor)
                .clipShape(Circle())
                .shadow(color: accentColor.opacity(0.5), radius: 8, x: 0, y: 4)
        }
        .padding(.trailing, 20)
        .padding(.bottom, 24)
    }

    // MARK: - Delete post

    private func deletePost(_ post: CommunityPost) async {
        await viewModel.deletePost(post)
    }
}

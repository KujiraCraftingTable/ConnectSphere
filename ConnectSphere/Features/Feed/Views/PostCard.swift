import SwiftUI

struct PostCard: View {
    @Environment(AppState.self) var appState
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.appBundle) var bundle
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.openURL) private var openURL
    @State private var isLiked:      Bool
    @State private var likeCount:    Int
    @State private var commentCount: Int
    @State private var shareCount:   Int
    @State private var showComments  = false
    @State private var showShareSheet = false

    // Action states
    @State private var showDeleteAlert = false
    @State private var showEditSheet   = false
    @State private var isHidden        = false   // ẩn bài người khác cục bộ
    @State private var showReportDialog  = false
    @State private var showReportResult  = false
    @State private var reportResultMessage = ""

    var post: Post
    var disableSelfNavigation: Bool = false
    var onOwnAvatarTapped: (() -> Void)? = nil
    var onCommentAdded: (() -> Void)? = nil
    /// Gọi khi người dùng xoá bài của chính mình thành công
    var onPostDeleted: (() -> Void)? = nil
    /// Gọi khi người dùng lưu chỉnh sửa bài viết thành công
    var onPostUpdated: ((Post) -> Void)? = nil

    @State private var shakeAmount: CGFloat = 0
    private let repository = PostRepository()

    init(
        post: Post,
        disableSelfNavigation: Bool = false,
        onOwnAvatarTapped: (() -> Void)? = nil,
        onCommentAdded: (() -> Void)? = nil,
        onPostDeleted: (() -> Void)? = nil,
        onPostUpdated: ((Post) -> Void)? = nil
    ) {
        self.post = post
        self.disableSelfNavigation = disableSelfNavigation
        self.onOwnAvatarTapped = onOwnAvatarTapped
        self.onCommentAdded = onCommentAdded
        self.onPostDeleted = onPostDeleted
        self.onPostUpdated = onPostUpdated
        _isLiked      = State(initialValue: post.isLiked)
        _likeCount    = State(initialValue: post.likeCount)
        _commentCount = State(initialValue: post.commentCount)
        _shareCount   = State(initialValue: post.shareCount)
    }

    @ViewBuilder
    var body: some View {
        if !isHidden {
            mainCard
        }
    }

    private var mainCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            postHeader

            // Content — chỉ hiện nếu có text thật
            if !post.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(linkifiedContent)
                    .font(.system(size: 15))
                    .foregroundColor(AppColors.textPrimary(colorScheme))
                    .tint(themeManager.theme.primary)
                    .environment(\.openURL, OpenURLAction { url in
                        openURL(url); return .handled
                    })
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
            }

            // Hashtag chips — bấm vào mở TagFeedView duyệt theo tag
            if !post.tags.isEmpty {
                hashtagRow
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
            }

            // Link preview card (nếu có link_url)
            if let linkUrl = post.linkUrl, let url = URL(string: linkUrl) {
                linkPreviewCard(url: url)
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
            }
            // Ảnh upload thật — lưới kiểu Facebook, hỗ trợ nhiều ảnh
            else if !post.displayImageUrls.isEmpty {
                PostPhotoGrid(urls: post.displayImageUrls)
                    .padding(.top, 10)
            }

            // Bài gốc được nhúng (nếu đây là bài share)
            if post.sharedPostId != nil {
                sharedPostEmbed
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
            }

            postStats
            Divider().padding(.horizontal, 12)
            actionButtons
        }
        .background(AppColors.surface(colorScheme))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .offset(x: shakeAmount)
        // Comment sheet
        .sheet(isPresented: $showComments) {
            CommentSheet(postId: post.id) {
                commentCount += 1
                onCommentAdded?()
            }
            .environment(appState)
        }
        // Edit sheet — tái sử dụng CreatePostView với editingPost
        .sheet(isPresented: $showEditSheet) {
            CreatePostView(editingPost: post, onPostUpdated: { updatedPost in
                onPostUpdated?(updatedPost)
            })
            .environment(appState)
            .environment(themeManager)
        }
        // Share sheet
        .sheet(isPresented: $showShareSheet) {
            SharePostSheet(post: post) {
                shareCount += 1
            }
            .environment(appState)
            .environment(themeManager)
        }
        // Delete confirmation alert
        .alert(bundle.loc("Delete post?"), isPresented: $showDeleteAlert) {
            Button(bundle.loc("Delete"), role: .destructive) {
                Task { await handleDeletePost() }
            }
            Button(bundle.loc("Cancel"), role: .cancel) {}
        } message: {
            Text("This post will be permanently deleted.", bundle: bundle)
        }
        // Report reason picker
        .confirmationDialog(
            bundle.loc("Why are you reporting this content?"),
            isPresented: $showReportDialog,
            titleVisibility: .visible
        ) {
            ForEach(ReportReason.allCases, id: \.self) { reason in
                Button(reason.displayName) {
                    Task { await handleReportPost(reason: reason) }
                }
            }
            Button(bundle.loc("Cancel"), role: .cancel) {}
        }
        // Report result feedback
        .alert(reportResultMessage, isPresented: $showReportResult) {
            Button(bundle.loc("Done")) {}
        }
    }

    // MARK: Report

    /// Gửi báo cáo bài viết với lý do được chọn
    private func handleReportPost(reason: ReportReason) async {
        do {
            try await repository.reportPost(postId: post.id, reason: reason)
            reportResultMessage = bundle.loc("Report submitted")
        } catch {
            #if DEBUG
            print("[PostCard] reportPost error: \(error)")
            #endif
            reportResultMessage = bundle.loc("Could not submit report. Please try again.")
        }
        showReportResult = true
    }

    // MARK: Delete

    /// Gọi API soft-delete rồi thông báo cho parent feed xoá card này
    private func handleDeletePost() async {
        do {
            try await repository.deletePost(postId: post.id)
            NotificationCenter.default.post(name: .postDeleted, object: nil, userInfo: [
                "id": post.id,
                "authorId": post.author.id
            ])
            onPostDeleted?()
        } catch {
            #if DEBUG
            print("[PostCard] deletePost error: \(error)")
            #endif
        }
    }

    // MARK: Shake

    private func triggerShake() {
        let step = 0.07
        withAnimation(.easeInOut(duration: step)) { shakeAmount = 10 }
        DispatchQueue.main.asyncAfter(deadline: .now() + step * 1) {
            withAnimation(.easeInOut(duration: step)) { shakeAmount = -10 }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + step * 2) {
            withAnimation(.easeInOut(duration: step)) { shakeAmount = 10 }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + step * 3) {
            withAnimation(.easeInOut(duration: step)) { shakeAmount = -10 }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + step * 4) {
            withAnimation(.easeInOut(duration: step)) { shakeAmount = 0 }
        }
    }

    // MARK: Linkified content

    private var linkifiedContent: AttributedString {
        var result = AttributedString(post.content)
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let matches = detector?.matches(in: post.content, range: NSRange(post.content.startIndex..., in: post.content)) ?? []
        for match in matches {
            guard let url = match.url, let range = Range(match.range, in: post.content) else { continue }
            if let attrRange = Range(range, in: result) {
                result[attrRange].link = url
                result[attrRange].foregroundColor = Color.blue
            }
        }
        return result
    }

    // MARK: Link Preview Card

    private func linkPreviewCard(url: URL) -> some View {
        Button { openURL(url) } label: {
            VStack(spacing: 0) {
                // Thumbnail
                if let imageUrl = post.imageUrl.flatMap({ URL(string: $0) }) {
                    AsyncImage(url: imageUrl) { phase in
                        switch phase {
                        case .success(let img):
                            img.resizable().scaledToFill()
                                .frame(maxWidth: .infinity).frame(height: 180)
                                .clipped()
                        default:
                            Rectangle().fill(AppColors.base(colorScheme))
                                .frame(maxWidth: .infinity).frame(height: 100)
                        }
                    }
                }

                // Title + domain
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(url.host ?? url.absoluteString)
                            .font(.system(size: 11))
                            .foregroundColor(AppColors.textSecondary(colorScheme))
                            .textCase(.uppercase)
                        if let title = post.articleTitle {
                            Text(title)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(AppColors.textPrimary(colorScheme))
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                        }
                    }
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 12))
                        .foregroundColor(AppColors.textSecondary(colorScheme))
                }
                .padding(10)
                .background(AppColors.base(colorScheme))
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(AppColors.borderDefault(colorScheme), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    // MARK: Header

    private var postHeader: some View {
        HStack(alignment: .top, spacing: 10) {
            // Avatar → shake (profile bản thân) | tab Profile (feed bản thân) | UserProfileView (người khác)
            let isSelf = post.author.id == appState.currentUser?.id
            if disableSelfNavigation && isSelf {
                Button { triggerShake() } label: {
                    AvatarView(user: post.author, size: 42)
                }
                .buttonStyle(.plain)
            } else if isSelf, let onTap = onOwnAvatarTapped {
                Button { onTap() } label: {
                    AvatarView(user: post.author, size: 42)
                }
                .buttonStyle(.plain)
            } else {
                NavigationLink(destination:
                    UserProfileView(userId: post.author.id, preloadedUser: post.author)
                        .environment(appState)
                ) {
                    AvatarView(user: post.author, size: 42)
                }
                .buttonStyle(.plain)
            }

            VStack(alignment: .leading, spacing: 3) {
                // Name + Connect button in one row
                HStack(spacing: 8) {
                    NavigationLink(destination:
                        UserProfileView(userId: post.author.id, preloadedUser: post.author)
                            .environment(appState)
                    ) {
                        Text(post.author.name)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(AppColors.textPrimary(colorScheme))
                    }
                    .buttonStyle(.plain)

                    // Chỉ hiện Connect nếu không phải chính mình
                    if post.author.id != appState.currentUser?.id {
                        ConnectButton(targetUserId: post.author.id, compact: true)
                    }
                }

                if post.mode == .work,
                   let title = post.author.jobTitle,
                   let company = post.author.company {
                    Text("\(title) · \(company)")
                        .font(.system(size: 12))
                        .foregroundColor(AppColors.textSecondary(colorScheme))
                }

                HStack(spacing: 3) {
                    Text(post.timestamp.timeAgoString)
                    Text("·")
                    Image(systemName: post.privacy == .publicAll ? "globe.americas" : post.privacy.icon)
                }
                .font(.system(size: 12))
                .foregroundColor(AppColors.textSecondary(colorScheme))
            }

            Spacer()

            Menu {
                let isSelf = post.author.id == appState.currentUser?.id
                if isSelf {
                    Button { showEditSheet = true } label: {
                        Label(bundle.loc("Edit post"), systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        // Delay để menu dismiss xong trước khi alert xuất hiện (SwiftUI timing bug)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            showDeleteAlert = true
                        }
                    } label: {
                        Label(bundle.loc("Delete post"), systemImage: "trash")
                    }
                } else {
                    Button {
                        // Ẩn ngay trên UI, đồng thời persist để reload không hiện lại
                        withAnimation { isHidden = true }
                        Task { try? await repository.hidePost(postId: post.id) }
                    } label: {
                        Label(bundle.loc("Hide post"), systemImage: "eye.slash")
                    }
                    Button(role: .destructive) {
                        showReportDialog = true
                    } label: {
                        Label(bundle.loc("Report post"), systemImage: "flag")
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 18))
                    .foregroundColor(AppColors.textSecondary(colorScheme))
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
    }

    // MARK: Hashtag Chips

    /// Danh sách hashtag của bài viết — bấm vào 1 chip mở TagFeedView duyệt theo tag đó
    private var hashtagRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(post.tags, id: \.self) { tag in
                    NavigationLink(destination: TagFeedView(tag: tag)) {
                        Text("#\(tag)")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(themeManager.theme.primary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(themeManager.theme.primary.opacity(0.12), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: Stats Row

    private var postStats: some View {
        HStack {
            if likeCount > 0 {
                HStack(spacing: 4) {
                    ZStack {
                        Circle().fill(themeManager.theme.primary).frame(width: 18, height: 18)
                        Image(systemName: "hand.thumbsup.fill")
                            .font(.system(size: 9))
                            .foregroundColor(.white)
                    }
                    Text("\(likeCount)")
                        .font(.system(size: 13))
                        .foregroundColor(AppColors.textSecondary(colorScheme))
                }
            }
            Spacer()
            HStack(spacing: 10) {
                if commentCount > 0 {
                    Text(String(format: bundle.loc("%d comments"), commentCount))
                        .font(.system(size: 13))
                        .foregroundColor(AppColors.textSecondary(colorScheme))
                }
                if shareCount > 0 {
                    Text(String(format: bundle.loc("%d shares"), shareCount))
                        .font(.system(size: 13))
                        .foregroundColor(AppColors.textSecondary(colorScheme))
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: Action Buttons

    private var actionButtons: some View {
        HStack {
            // Like + Comment — bottom left
            HStack(spacing: 16) {
                Button {
                    Task {
                        guard let token = KeychainHelper.load(forKey: KeychainHelper.tokenKey) else { return }
                        isLiked   = !isLiked
                        likeCount += isLiked ? 1 : -1
                        guard let url = URL(string: APIConfig.baseURL + "/posts/\(post.id)/like") else { return }
                        var req = URLRequest(url: url)
                        req.httpMethod = "POST"
                        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                        if let (data, _) = try? await URLSession.shared.data(for: req),
                           let res = try? JSONDecoder().decode(LikeResponse.self, from: data) {
                            isLiked   = res.liked
                            likeCount = res.likeCount
                        }
                    }
                } label: {
                    Image(systemName: isLiked ? "hand.thumbsup.fill" : "hand.thumbsup")
                        .font(.system(size: 20))
                        .foregroundColor(isLiked ? themeManager.theme.primary : AppColors.textSecondary(colorScheme))
                }

                Button { showComments = true } label: {
                    Image(systemName: "bubble.left")
                        .font(.system(size: 20))
                        .foregroundColor(AppColors.textSecondary(colorScheme))
                }
            }

            Spacer()

            // Share — bottom right
            Button { showShareSheet = true } label: {
                Image(systemName: "arrowshape.turn.up.right")
                    .font(.system(size: 20))
                    .foregroundColor(AppColors.textSecondary(colorScheme))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: Shared post embed

    /// Card bài gốc nhúng trong bài share; bài gốc đã xóa → placeholder
    @ViewBuilder
    private var sharedPostEmbed: some View {
        Group {
            if let shared = post.sharedPost {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        AvatarView(user: shared.author, size: 30)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(shared.author.name)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(AppColors.textPrimary(colorScheme))
                            Text(shared.timestamp.timeAgoString)
                                .font(.system(size: 12))
                                .foregroundColor(AppColors.textSecondary(colorScheme))
                        }
                    }

                    if !shared.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(shared.content)
                            .font(.system(size: 14))
                            .foregroundColor(AppColors.textPrimary(colorScheme))
                            .lineLimit(6)
                    }

                    if !shared.displayImageUrls.isEmpty {
                        PostPhotoGrid(urls: shared.displayImageUrls, gridHeight: 200)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("This content no longer exists", bundle: bundle)
                    .font(.system(size: 14))
                    .foregroundColor(AppColors.textSecondary(colorScheme))
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(AppColors.base(colorScheme)))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(AppColors.borderDefault(colorScheme), lineWidth: 1)
        )
    }
}

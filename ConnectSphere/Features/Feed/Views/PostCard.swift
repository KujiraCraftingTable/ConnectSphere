import SwiftUI

struct PostCard: View {
    @Environment(AppState.self) var appState
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.appBundle) var bundle
    @Environment(\.colorScheme) var colorScheme
    @Environment(UndoToastPresenter.self) var toastPresenter
    @Environment(\.openURL) private var openURL
    @State private var isLiked:      Bool
    @State private var isSaved:      Bool
    @State private var likeCount:    Int
    @State private var commentCount: Int
    @State private var shareCount:   Int
    @State private var showComments  = false
    @State private var showShareSheet = false

    // Action states
    @State private var showDeleteAlert = false
    @State private var showEditSheet   = false
    @State private var isHidden        = false   // locally hides someone else's post
    @State private var showReportDialog  = false
    @State private var showReportResult  = false
    @State private var reportResultMessage = ""

    var post: Post
    var disableSelfNavigation: Bool = false
    var onOwnAvatarTapped: (() -> Void)? = nil
    var onCommentAdded: (() -> Void)? = nil
    /// Called when the user successfully deletes their own post
    var onPostDeleted: (() -> Void)? = nil
    /// Called when the user successfully saves an edit to the post
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
        _isSaved      = State(initialValue: post.isSaved)
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

            // Content — only shown if there's actual text
            if !post.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(linkifiedContent)
                    .appFont(.body)
                    .foregroundColor(AppColors.textPrimary(colorScheme))
                    .tint(themeManager.theme.primary)
                    .environment(\.openURL, OpenURLAction { url in
                        openURL(url); return .handled
                    })
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
            }

            // Hashtag chips — tapping one opens TagFeedView to browse by tag
            if !post.tags.isEmpty {
                hashtagRow
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
            }

            // Link preview card (if there's a link_url)
            if let linkUrl = post.linkUrl, let url = URL(string: linkUrl) {
                linkPreviewCard(url: url)
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
            }
            // Real uploaded images — Facebook-style grid, supports multiple images
            else if !post.displayImageUrls.isEmpty {
                PostPhotoGrid(urls: post.displayImageUrls)
                    .padding(.top, 10)
            }

            // Embedded original post (if this is a shared post)
            if post.sharedPostId != nil {
                sharedPostEmbed
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
            }

            // Poll or Event inline body — same PollPostCard/EventPostCard used by
            // CommunityPostCard, drop-in reusable since both view models are
            // fully post-id/event-id generic (no community coupling).
            switch post.postType {
            case .poll:
                if let pollData = post.pollData {
                    PollPostCard(
                        vm: PollViewModel(postId: post.id, pollData: pollData, token: appState.authToken ?? ""),
                        accentColor: themeManager.theme.primary
                    )
                    .padding(.top, 10)
                }
            case .event:
                if let eventData = post.eventData {
                    EventPostCard(
                        vm: EventViewModel(eventData: eventData, token: appState.authToken ?? ""),
                        accentColor: themeManager.theme.primary
                    )
                    .padding(.top, 10)
                }
            case .text:
                EmptyView()
            }

            Divider().padding(.horizontal, 12).padding(.top, 8)
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
        // Edit sheet — reuses CreatePostView with editingPost
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
            Text("This post won't be shown in the app. You can restore it from Recently Deleted within 30 days.", bundle: bundle)
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

    /// Submits a post report with the selected reason
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

    /// Calls the soft-delete API then notifies the parent feed to remove this card —
    /// while also showing an Undo toast, letting the user restore it within a few
    /// seconds before the post truly "disappears" from reach (it's still in Recently
    /// Deleted for 30 days).
    private func handleDeletePost() async {
        do {
            try await repository.deletePost(postId: post.id)
            NotificationCenter.default.post(name: .postDeleted, object: nil, userInfo: [
                "id": post.id,
                "authorId": post.author.id
            ])
            onPostDeleted?()

            let deletedPostId = post.id
            toastPresenter.show(message: bundle.loc("Post deleted")) {
                Task {
                    let restoreRepository = PostRepository()
                    if let restored = try? await restoreRepository.restorePost(postId: deletedPostId) {
                        NotificationCenter.default.post(name: .postRestored, object: nil, userInfo: [
                            "post": restored
                        ])
                    }
                }
            }
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
                result[attrRange].foregroundColor = themeManager.theme.primary
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
            // Avatar → shake (own profile) | Profile tab (own feed) | UserProfileView (someone else)
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
                            .appFont(.headline)
                            .foregroundColor(AppColors.textPrimary(colorScheme))
                    }
                    .buttonStyle(.plain)

                    // Only show Connect if this isn't the current user
                    if post.author.id != appState.currentUser?.id {
                        ConnectButton(targetUserId: post.author.id, compact: true)
                    }
                }

                if post.mode == .work,
                   let title = post.author.jobTitle,
                   let company = post.author.company {
                    Text("\(title) · \(company)")
                        .appFont(.footnote)
                        .foregroundColor(AppColors.textSecondary(colorScheme))
                }

                HStack(spacing: 3) {
                    Text(post.timestamp.timeAgoString)
                    Text("·")
                    Image(systemName: post.privacy == .publicAll ? "globe.americas" : post.privacy.icon)
                }
                .appFont(.footnote)
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
                        // Delay so the menu finishes dismissing before the alert appears (SwiftUI timing bug)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            showDeleteAlert = true
                        }
                    } label: {
                        Label(bundle.loc("Delete post"), systemImage: "trash")
                    }
                } else {
                    Button {
                        // Hide immediately in the UI, and also persist so a reload doesn't bring it back
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

    /// List of the post's hashtags — tapping a chip opens TagFeedView to browse that tag
    private var hashtagRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: AppSpacing.sm) {
                ForEach(post.tags, id: \.self) { tag in
                    NavigationLink(destination: TagFeedView(tag: tag, mode: appState.currentMode)) {
                        Chip(text: "#\(tag)", style: .neutral)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: Action Buttons

    /// Count shown immediately to the right of an action icon (hidden at 0) —
    /// same style the old FB-style summary row above the divider used to have.
    @ViewBuilder
    private func actionCount(_ value: Int) -> some View {
        if value > 0 {
            Text("\(value)")
                .appFont(.subheadline)
                .foregroundColor(AppColors.textSecondary(colorScheme))
        }
    }

    private var actionButtons: some View {
        HStack {
            // Like + Comment — bottom left
            HStack(spacing: 16) {
                Button {
                    Task {
                        // Optimistic toggle, then reconcile with the server —
                        // and roll back (like the Save button below) if it fails.
                        let wasLiked = isLiked
                        let wasCount = likeCount
                        isLiked   = !isLiked
                        likeCount += isLiked ? 1 : -1
                        do {
                            let res = try await repository.toggleLike(postId: post.id)
                            isLiked   = res.liked
                            likeCount = res.likeCount
                        } catch {
                            isLiked   = wasLiked
                            likeCount = wasCount
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: isLiked ? "hand.thumbsup.fill" : "hand.thumbsup")
                            .font(.system(size: 20))
                            .foregroundColor(isLiked ? themeManager.theme.primary : AppColors.textSecondary(colorScheme))
                        actionCount(likeCount)
                    }
                }

                Button { showComments = true } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "bubble.left")
                            .font(.system(size: 20))
                            .foregroundColor(AppColors.textSecondary(colorScheme))
                        actionCount(commentCount)
                    }
                }
            }

            Spacer()

            // Save + Share — bottom right
            HStack(spacing: 16) {
                Button {
                    Task {
                        isSaved.toggle()
                        do {
                            if isSaved { try await repository.savePost(postId: post.id) }
                            else       { try await repository.unsavePost(postId: post.id) }
                            var updated = post
                            updated.isSaved = isSaved
                            NotificationCenter.default.post(name: .postUpdated, object: nil, userInfo: ["post": updated])
                        } catch {
                            isSaved.toggle() // revert on failure
                        }
                    }
                } label: {
                    Image(systemName: isSaved ? "bookmark.fill" : "bookmark")
                        .font(.system(size: 20))
                        .foregroundColor(isSaved ? themeManager.theme.primary : AppColors.textSecondary(colorScheme))
                }

                Button { showShareSheet = true } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrowshape.turn.up.right")
                            .font(.system(size: 20))
                            .foregroundColor(AppColors.textSecondary(colorScheme))
                        actionCount(shareCount)
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: Shared post embed

    /// Card for the original post embedded in a shared post; deleted original → placeholder
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

import SwiftUI

struct CommunityPostCard: View {
    @Environment(AppState.self) var appState
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.appBundle) var bundle
    @Environment(\.openURL) private var openURL
    var post: CommunityPost
    let currentUserId: String
    let communityId: String
    let token: String
    let accentColor: Color
    let currentUserRole: MemberRole?
    let onDelete: (() -> Void)?
    let onPin: (() -> Void)?
    let onUnpin: (() -> Void)?

    @State private var showReportSheet = false
    @State private var showCommentSheet = false
    @State private var isLiked: Bool
    @State private var likeCount: Int
    @State private var commentCount: Int
    private let repository = CommunityRepository()

    init(
        post: CommunityPost,
        currentUserId: String,
        communityId: String,
        token: String,
        accentColor: Color,
        currentUserRole: MemberRole?,
        onDelete: (() -> Void)?,
        onPin: (() -> Void)?,
        onUnpin: (() -> Void)?
    ) {
        self.post            = post
        self.currentUserId   = currentUserId
        self.communityId     = communityId
        self.token           = token
        self.accentColor     = accentColor
        self.currentUserRole = currentUserRole
        self.onDelete        = onDelete
        self.onPin           = onPin
        self.onUnpin         = onUnpin
        _isLiked      = State(initialValue: post.isLiked)
        _likeCount    = State(initialValue: post.likeCount)
        _commentCount = State(initialValue: post.commentCount)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // Pinned label banner
            if post.isPinned {
                HStack(spacing: 4) {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 11))
                    Text(bundle.loc("Pinned"))
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundColor(accentColor)
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 2)
            }

            // Header: avatar + author + time + action menu
            HStack(alignment: .top, spacing: 10) {
                authorAvatar
                VStack(alignment: .leading, spacing: 2) {
                    Text(post.author.displayName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(AppColors.textPrimary(colorScheme))
                    Text(post.createdAt.timeAgoString)
                        .font(.system(size: 12))
                        .foregroundColor(AppColors.textTertiary(colorScheme))
                }
                Spacer()
                actionMenu
            }
            .padding(.horizontal, 14)
            .padding(.top, post.isPinned ? 4 : 12)

            // Community tag (shown outside community context)
            if let community = post.community {
                HStack(spacing: 4) {
                    Text(community.iconEmoji).font(.system(size: 12))
                    Text(community.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(AppColors.textSecondary(colorScheme))
                }
                .padding(.horizontal, 14)
                .padding(.top, 6)
            }

            // Post content text
            Text(post.content)
                .font(.system(size: 15))
                .foregroundColor(AppColors.textPrimary(colorScheme))
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, hasMediaBelowContent ? 8 : 14)

            // Hashtag chips — parity with Feed's PostCard
            if !post.tags.isEmpty {
                hashtagRow
                    .padding(.horizontal, 14)
                    .padding(.top, 2)
                    .padding(.bottom, 8)
            }

            // Link preview card (if link_url is present) — mirrors PostCard's treatment
            if let linkUrl = post.linkUrl, let url = URL(string: linkUrl) {
                linkPreviewCard(url: url)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
            }
            // Real uploaded images — uses the same PostPhotoGrid component Feed uses, so
            // images in a community post look identical to images in a Feed post.
            else if !post.displayImageUrls.isEmpty {
                PostPhotoGrid(urls: post.displayImageUrls)
                    .padding(.bottom, 8)
            }

            // Poll or Event inline body
            switch post.postType {
            case .poll:
                if let pollData = post.pollData {
                    PollPostCard(
                        vm: PollViewModel(postId: post.id, pollData: pollData, token: token),
                        accentColor: accentColor
                    )
                }
            case .event:
                if let eventData = post.eventData {
                    EventPostCard(
                        vm: EventViewModel(eventData: eventData, token: token),
                        accentColor: accentColor
                    )
                }
            case .text:
                EmptyView()
            }

            Divider()
                .background(AppColors.borderSubtle(colorScheme))

            // Footer: like + comment buttons
            HStack(spacing: 20) {
                Button {
                    Task { await toggleLike() }
                } label: {
                    Label("\(likeCount)", systemImage: isLiked ? "heart.fill" : "heart")
                        .font(.system(size: 13))
                        .foregroundColor(isLiked ? .red : AppColors.textSecondary(colorScheme))
                }
                .buttonStyle(.plain)

                Button {
                    showCommentSheet = true
                } label: {
                    Label("\(commentCount)", systemImage: "bubble.right")
                        .font(.system(size: 13))
                        .foregroundColor(AppColors.textSecondary(colorScheme))
                }
                .buttonStyle(.plain)

                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .surfaceBackground()
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.2 : 0.05), radius: 4, x: 0, y: 2)
        .sheet(isPresented: $showReportSheet) {
            ReportSheet(
                targetType:  "post",
                targetId:    post.id,
                communityId: communityId,
                token:       token
            )
        }
        .sheet(isPresented: $showCommentSheet) {
            CommentSheet(postId: post.id) {
                commentCount += 1
            }
            .environment(appState)
        }
        // `isLiked`/`likeCount`/`commentCount` are local @State (seeded once
        // from `post` in `init`, per the optimistic-update pattern above) so
        // they don't get overwritten mid-gesture by a fresh `post` value on
        // every parent re-render. `CommunityDetailViewModel`'s socket
        // listeners patch `post` in place when a live update arrives for
        // THIS post (`community_post_liked`/`community_post_commented`) — these
        // three `onChange`s are what let that reach the screen, resyncing the
        // local copies to the server-authoritative value without fighting our
        // own optimistic writes above (those also converge to the same
        // absolute values, so this is a same-value confirm, not a conflict).
        .onChange(of: post.likeCount) { _, newValue in likeCount = newValue }
        .onChange(of: post.isLiked) { _, newValue in isLiked = newValue }
        .onChange(of: post.commentCount) { _, newValue in commentCount = newValue }
    }

    // MARK: - Actions

    /// Toggle like on a community post; updates optimistically then syncs with the response.
    private func toggleLike() async {
        isLiked.toggle()
        likeCount += isLiked ? 1 : -1
        guard let result = try? await repository.toggleLikePost(postId: post.id, token: token) else { return }
        isLiked   = result.liked
        likeCount = result.likeCount
    }

    // MARK: - Subviews

    /// True when a tag/link/image renders right below the content — used to drop the extra
    /// bottom padding on the content text, avoiding double spacing between content and media.
    private var hasMediaBelowContent: Bool {
        !post.tags.isEmpty || post.linkUrl != nil || !post.displayImageUrls.isEmpty
    }

    /// The post's hashtag list — tapping a chip opens TagFeedView browsing by that tag
    /// (same component Feed's PostCard uses; tags aren't distinguished between Feed/Community).
    private var hashtagRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(post.tags, id: \.self) { tag in
                    NavigationLink(destination: TagFeedView(tag: tag, mode: appState.currentMode)) {
                        Text("#\(tag)")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(accentColor)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(accentColor.opacity(0.12), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// Link preview card — same layout as Feed's PostCard.linkPreviewCard
    /// (thumbnail + domain + article title) so a community post looks identical to a Feed post.
    private func linkPreviewCard(url: URL) -> some View {
        Button { openURL(url) } label: {
            VStack(spacing: 0) {
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

    private var authorAvatar: some View {
        ZStack {
            Circle().fill(Color(hex: post.author.avatarColor))
            Text(String(post.author.displayName.prefix(1)))
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.white)
        }
        .frame(width: 36, height: 36)
    }

    @ViewBuilder
    private var actionMenu: some View {
        let isAuthor = post.author.id == currentUserId
        let isStaff  = currentUserRole == .admin || currentUserRole == .moderator

        // Always show menu — either for owner/staff actions or for report option
        Menu {
            // Pin / Unpin (admin & mod only)
            if isStaff {
                if post.isPinned {
                    Button { onUnpin?() } label: {
                        Label(bundle.loc("Unpin post"), systemImage: "pin.slash")
                    }
                } else {
                    Button { onPin?() } label: {
                        Label(bundle.loc("Pin post"), systemImage: "pin")
                    }
                }
                Divider()
            }

            // Delete (author, admin, mod)
            if let onDelete, (isAuthor || isStaff) {
                Button(role: .destructive, action: onDelete) {
                    Label(bundle.loc("Delete post"), systemImage: "trash")
                }
                Divider()
            }

            // Report (non-authors only; reporter identity is hidden server-side)
            if !isAuthor {
                Button {
                    showReportSheet = true
                } label: {
                    Label(bundle.loc("Report post"), systemImage: "flag")
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 16))
                .foregroundColor(AppColors.textTertiary(colorScheme))
                .frame(width: 32, height: 32)
        }
    }
}

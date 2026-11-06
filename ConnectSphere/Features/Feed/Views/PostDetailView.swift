import SwiftUI

/// The pending "open this post" navigation on a Feed surface. Held in a
/// `@State PostRoute?` that drives a `.navigationDestination`. `focusComposer`
/// opens the screen with the comment field already focused (what the comment
/// button does, vs. a plain body tap).
struct PostRoute: Hashable {
    let postId: String
    var focusComposer: Bool = false
}

/// Full-screen view of a single post with its comments below it, scrolling as
/// one page under a top bar that holds the author and the ⋯ menu, and a
/// pinned comment composer. Reached by tapping a post in the feed, tapping a
/// post's comment button (`focusComposer: true`), or from a like/comment
/// notification (`scrollToCommentId`).
struct PostDetailView: View {
    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(UndoToastPresenter.self) private var toastPresenter
    @Environment(\.appBundle) private var bundle
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    let postId: String
    /// When opened from a comment notification, scroll to this comment on load.
    var scrollToCommentId: String? = nil
    /// Set while the jumped-to comment is flashing.
    @State private var highlightedCommentId: String?
    /// When opened from a comment button, focus the composer on appear.
    var focusComposer: Bool = false

    @State private var viewModel: PostDetailViewModel
    @State private var commentVM = CommentViewModel()
    @State private var draft = ""
    @State private var draftSelection: TextSelection?
    /// The screen's width. The top bar's author block fills what the back
    /// and ⋯ buttons leave, so it sits left beside the back button.
    @State private var screenWidth: CGFloat = 0
    @FocusState private var composerFocused: Bool

    init(postId: String, scrollToCommentId: String? = nil, focusComposer: Bool = false) {
        self.postId = postId
        self.scrollToCommentId = scrollToCommentId
        self.focusComposer = focusComposer
        _viewModel = State(initialValue: PostDetailViewModel(postId: postId))
    }

    private var post: Post? { viewModel.post }

    // A Marketplace item opens here like any post. Likes and comments
    // included. The seller's tools (sold, re-up, edit) are on its item page,
    // reached from the Marketplace grid and "Your items".
    var body: some View {
        // ScrollViewReader wraps the whole screen body (not just the
        // ScrollView below) so the composer's Send button can also reach
        // `proxy`, it needs to scroll to a just-sent comment directly,
        // deterministically, rather than inferring "a comment was added"
        // from a comments-count change (that approach raced against
        // @Observable's deferred change notification and auto-scrolled
        // on the initial load too; see PostCard/CommentSheet history).
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                // The post and its comments scroll as one page. Two cards like
                // the feed's, while the author and the ⋯ menu sit in the top
                // bar, so a long post or thread gets the whole screen.
                ScrollView {
                    VStack(spacing: AppSpacing.sm) {
                        if let post {
                            PostCard(
                                post: post,
                                onPostDeleted: { dismiss() },
                                onPostUpdated: { viewModel.post = $0 },
                                onCommentTap: { composerFocused = true },
                                showsHeader: false
                            )
                            .cardStyle()
                            commentsCard(post)
                        } else if viewModel.loadFailed {
                            errorState
                        } else {
                            ProgressView().padding(.top, 80)
                        }
                    }
                    .padding(.horizontal, AppSpacing.sm)
                    .padding(.vertical, AppSpacing.sm)
                }
                .scrollDismissesKeyboard(.interactively)
                .simultaneousGesture(TapGesture().onEnded { composerFocused = false })
                .task { await loadAll(proxy: proxy) }

                if post != nil {
                    composerBar(proxy: proxy)
                }
            }
        }
        .background(AppColors.base(colorScheme))
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { screenWidth = $0 }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar { topBar }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                if composerFocused { MarkdownToolbar(text: $draft, selection: $draftSelection) }
            }
        }
    }

    // MARK: - Top bar

    /// The back button (system), the author beside it, and the post's ⋯ menu
    ///, Facebook-style, one row instead of a title bar above the post's own
    /// header.
    @ToolbarContentBuilder
    private var topBar: some ToolbarContent {
        if let post {
            // Back and ⋯ are 44 pt glass circles, 16 pt from the edges, 8 pt gaps.
            PostDetailAuthorItem(post: post, width: max(0, screenWidth - 2 * (16 + 44 + 8)))
            if let actions = viewModel.actions {
                ToolbarItem(placement: .topBarTrailing) {
                    PostOptionsMenu(
                        post: post,
                        actions: actions,
                        onPostDeleted: { dismiss() },
                        onPostUpdated: { viewModel.post = $0 },
                        onPostHidden: { dismiss() },
                        inToolbar: true
                    )
                }
            }
        }
    }

    // MARK: - Load

    private func loadAll(proxy: ScrollViewProxy) async {
        let firstLoad = viewModel.post == nil
        guard await viewModel.loadPost() else { return }
        if firstLoad { await commentVM.load(postId: postId) }

        // Ids arrive lowercase from some places (the activity log) and uppercase
        // from the comments list; match them as the same id.
        if let wanted = scrollToCommentId,
           let target = commentVM.comments.first(where: { $0.id.caseInsensitiveCompare(wanted) == .orderedSame })?.id {
            try? await Task.sleep(for: .milliseconds(300))
            withAnimation { proxy.scrollTo(target, anchor: .center) }
            highlightedCommentId = target
            try? await Task.sleep(for: .milliseconds(1600))
            if highlightedCommentId == target { highlightedCommentId = nil }
        }
        if focusComposer {
            try? await Task.sleep(for: .milliseconds(350))
            composerFocused = true
        }
    }

    // MARK: - Comment count

    private func adjustCommentCount(by delta: Int) { viewModel.adjustCommentCount(by: delta) }

    // MARK: - Comments

    private func commentsCard(_ post: Post) -> some View {
        VStack(spacing: 0) {
            commentsHeader(count: post.commentCount)
            CommentsSection(
                postId: postId,
                communityId: post.community?.id,
                postAuthorId: post.author.id,
                viewModel: commentVM,
                toastPresenter: toastPresenter,
                // Next run-loop turn: the page's dismiss-on-tap fires
                // for this same tap and would otherwise win.
                onReplyRequested: { Task { @MainActor in composerFocused = true } },
                highlightedCommentId: highlightedCommentId,
                onCommentCountChange: { delta in adjustCommentCount(by: delta) }
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }


    private func commentsHeader(count: Int) -> some View {
        Text(String(format: bundle.loc("Comments · %d"), count))
            .scaledFont(15, .semibold)
            .foregroundColor(AppColors.textPrimary(colorScheme))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, AppSpacing.md)
            .padding(.top, AppSpacing.md)
            .padding(.bottom, AppSpacing.xs)
    }

    // MARK: - Composer

    /// Floating on the grey background. A rounded "Replying to" chip (when
    /// replying) above an avatar + pill field + send row, instead of a
    /// full-width slab with a divider.
    private func composerBar(proxy: ScrollViewProxy) -> some View {
        VStack(spacing: AppSpacing.xs) {
            if let replying = commentVM.replyingTo {
                HStack(spacing: 8) {
                    Image(systemName: "arrowshape.turn.up.left.fill")
                        .scaledFont(12)
                        .foregroundColor(themeManager.theme.primary)
                    Text(String(format: bundle.loc("Replying to %@"), replying.author.displayName))
                        .scaledFont(13)
                        .foregroundColor(AppColors.textSecondary(colorScheme))
                    Spacer()
                    Button { commentVM.replyingTo = nil } label: {
                        Image(systemName: "xmark.circle.fill")
                            .scaledFont(16)
                            .foregroundColor(AppColors.textSecondary(colorScheme).opacity(0.6))
                    }
                    .accessibilityLabel(Bundle.app.loc("Cancel reply"))
                }
                .padding(.horizontal, AppSpacing.md)
                .padding(.vertical, 6)
                .background(themeManager.theme.primary.opacity(0.10), in: Capsule())
                .padding(.horizontal, AppSpacing.sm)
            }

            if commentVM.attachedPhoto != nil {
                CommentPhotoPreview(viewModel: commentVM)
                    .padding(.horizontal, AppSpacing.md)
            }

            HStack(spacing: 10) {
                if let me = appState.currentUser {
                    AvatarView(user: me, size: 36)
                }

                TextField(bundle.loc("Write a comment..."), text: $draft, selection: $draftSelection, axis: .vertical)
                    .scaledFont(15)
                    .lineLimit(4)
                    .focused($composerFocused)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(AppColors.surface(colorScheme), in: Capsule())
                    .overlay(Capsule().stroke(AppColors.borderDefault(colorScheme), lineWidth: 1))

                CommentPhotoButton(viewModel: commentVM)

                Button {
                    Task {
                        let text = draft
                        draft = ""
                        let ok = await commentVM.addComment(postId: postId, content: text)
                        if ok { adjustCommentCount(by: 1) }
                        // Reveal the comment/reply just sent. Triggered directly
                        // here (not inferred from a comments-count change) so it
                        // can't misfire on the initial load.
                        if ok, let last = commentVM.comments.last {
                            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                } label: {
                    Image(systemName: commentVM.isSending ? "clock" : "paperplane.fill")
                        .scaledFont(20)
                        .foregroundColor(commentVM.canSend(draft)
                                         ? themeManager.theme.primary : AppColors.textSecondary(colorScheme))
                }
                .accessibilityLabel(Bundle.app.loc("Send"))
                .disabled(!commentVM.canSend(draft))
            }
            .padding(.horizontal, AppSpacing.md)
        }
        .padding(.vertical, AppSpacing.sm)
    }

    // MARK: - Error state

    private var errorState: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.questionmark")
                .scaledFont(40)
                .foregroundColor(AppColors.textSecondary(colorScheme).opacity(0.4))
            Text("This post no longer exists or you don't have permission to view it", bundle: bundle)
                .scaledFont(15)
                .foregroundColor(AppColors.textSecondary(colorScheme))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .padding(.top, 80)
    }
}

// MARK: - Top bar author

/// The author item: the middle slot, sized to span the bar between the back
/// button and the ⋯ menu and left-aligned (a leading item is given too little
/// width and truncates the name), without the Liquid Glass capsule
/// iOS 26 puts behind toolbar items. It reads as the post's header.
private struct PostDetailAuthorItem: ToolbarContent {
    let post: Post
    let width: CGFloat

    var body: some ToolbarContent {
        if #available(iOS 26.0, *) {
            ToolbarItem(placement: .principal) {
                PostDetailHeader(post: post).frame(width: width, alignment: .leading)
            }
                .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .principal) {
                PostDetailHeader(post: post).frame(width: width, alignment: .leading)
            }
        }
    }
}

/// The compact form of `PostCard`'s header, for the top bar beside the back
/// button: avatar, name and "time · privacy", or, for a community post, the
/// community with "Posted by …". Opens the profile or the community.
private struct PostDetailHeader: View {
    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.appBundle) private var bundle
    @Environment(\.colorScheme) private var colorScheme

    let post: Post

    private func communityPage(_ community: CommunityRef) -> some View {
        CommunityDetailView(communityId: community.id, token: appState.authToken ?? "",
                            currentUserId: appState.currentUser?.id ?? "")
            .environment(appState).environment(themeManager)
    }

    @ViewBuilder
    var body: some View {
        if let community = post.community {
            // The community opens the community; the poster opens their
            // profile in it.
            HStack(spacing: 8) {
                NavigationLink(destination: communityPage(community)) {
                    Avatar(name: community.iconEmoji, imageURL: community.avatarUrl,
                           size: .sm, shape: .roundedSquare)
                }
                .buttonStyle(.plain)
                VStack(alignment: .leading, spacing: 1) {
                    NavigationLink(destination: communityPage(community)) { name(community.name) }
                        .buttonStyle(.plain)
                    detail {
                        CommunityProfileLink(communityId: community.id, userId: post.author.id) {
                            Text(String(format: bundle.loc("Posted by %@"), post.author.name))
                        }
                        Text("·")
                        Text(post.timestamp.timeAgoString)
                    }
                }
            }
        } else {
            NavigationLink(destination:
                UserProfileView(userId: post.author.id, preloadedUser: post.author)
                    .environment(appState)
            ) {
                HStack(spacing: 8) {
                    AvatarView(user: post.author, size: 34)
                    VStack(alignment: .leading, spacing: 1) {
                        name(post.author.name)
                        detail {
                            Text(post.timestamp.timeAgoString)
                            Text("·")
                            Image(systemName: post.privacy == .publicAll ? "globe.americas" : post.privacy.icon)
                        }
                    }
                }
            }
            .buttonStyle(.plain)
        }
    }

    private func name(_ text: String) -> some View {
        Text(text)
            .scaledFont(16, .semibold)
            .foregroundColor(AppColors.textPrimary(colorScheme))
            .lineLimit(1)
    }

    private func detail<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 3) { content() }
            .scaledFont(12)
            .foregroundColor(AppColors.textSecondary(colorScheme))
            .lineLimit(1)
    }
}

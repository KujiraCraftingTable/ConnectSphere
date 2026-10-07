import SwiftUI

/// The pending "open this post" navigation on a Feed surface — held in a
/// `@State PostRoute?` that drives a `.navigationDestination`. `focusComposer`
/// opens the screen with the comment field already focused (what the comment
/// button does, vs. a plain body tap).
struct PostRoute: Hashable {
    let postId: String
    var focusComposer: Bool = false
}

/// Full-screen view of a single post with its comments inline below it and a
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
    /// When opened from a comment button, focus the composer on appear.
    var focusComposer: Bool = false

    @State private var viewModel: PostDetailViewModel
    @State private var commentVM = CommentViewModel()
    @State private var draft = ""
    @FocusState private var composerFocused: Bool

    init(postId: String, scrollToCommentId: String? = nil, focusComposer: Bool = false) {
        self.postId = postId
        self.scrollToCommentId = scrollToCommentId
        self.focusComposer = focusComposer
        _viewModel = State(initialValue: PostDetailViewModel(postId: postId))
    }

    private var post: Post? { viewModel.post }

    var body: some View {
        // GeometryReader gives us the screen's own available height so the
        // pinned post can be capped at a quarter of it (expanding to at most
        // half) — without this, an unusually long post (long caption, several
        // photos, an embedded share) would push the whole comments panel
        // down/off-screen, since the post itself never scrolls away (see
        // PostCard.collapsedTotalHeight). A short post never actually uses
        // the full quarter — PostCard only clips once content genuinely
        // overflows it — so the comments panel gets whatever's left over.
        GeometryReader { geo in
            // ScrollViewReader wraps the whole screen body (not just the
            // ScrollView below) so the composer's Send button can also reach
            // `proxy` — it needs to scroll to a just-sent comment directly,
            // deterministically, rather than inferring "a comment was added"
            // from a comments-count change (that approach raced against
            // @Observable's deferred change notification and auto-scrolled
            // on the initial load too; see PostCard/CommentSheet history).
            ScrollViewReader { proxy in
                VStack(spacing: 0) {
                    // Pinned header — the post itself never scrolls away, so it can
                    // be read side by side with the comments; only the comment
                    // list below it scrolls. A rounded card like everywhere else
                    // in the app (same as FeedView's post cards).
                    if let post {
                        PostCard(
                            post: post,
                            onPostDeleted: { dismiss() },
                            onPostUpdated: { viewModel.post = $0 },
                            collapsedTotalHeight: geo.size.height / 4,
                            expandedTotalHeight: geo.size.height / 2
                        )
                        .cardStyle()
                        .padding(.horizontal, AppSpacing.sm)
                        .padding(.top, AppSpacing.sm)
                        .simultaneousGesture(TapGesture().onEnded { composerFocused = false })
                    }

                    // Comments panel: its own rounded card filling the rest of the
                    // height. The ScrollView always takes its full proposed height,
                    // so the card's fill covers the whole panel even with 0-1
                    // comments; the list scrolls inside the rounded corners.
                    VStack(spacing: 0) {
                        if let post {
                            commentsHeader(count: post.commentCount)
                        }
                        ScrollView {
                            if let post {
                                CommentsSection(
                                    postId: postId,
                                    postAuthorId: post.author.id,
                                    viewModel: commentVM,
                                    toastPresenter: toastPresenter,
                                    // Next run-loop turn: the panel's dismiss-on-tap fires
                                    // for this same tap and would otherwise win.
                                    onReplyRequested: { Task { @MainActor in composerFocused = true } },
                                    onCommentCountChange: { delta in adjustCommentCount(by: delta) }
                                )
                            } else if viewModel.loadFailed {
                                errorState
                            } else {
                                ProgressView().padding(.top, 80)
                            }
                        }
                        .scrollDismissesKeyboard(.interactively)
                    }
                    .simultaneousGesture(TapGesture().onEnded { composerFocused = false })
                    .cardStyle()
                    .padding(.horizontal, AppSpacing.sm)
                    .padding(.top, AppSpacing.sm)
                    .task { await loadAll(proxy: proxy) }

                    if post != nil {
                        composerBar(proxy: proxy)
                    }
                }
            }
        }
        .background(AppColors.base(colorScheme))
        .navigationTitle(bundle.loc("Posts"))
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Load

    private func loadAll(proxy: ScrollViewProxy) async {
        let firstLoad = viewModel.post == nil
        guard await viewModel.loadPost() else { return }
        if firstLoad { await commentVM.load(postId: postId) }

        if let target = scrollToCommentId {
            try? await Task.sleep(for: .milliseconds(300))
            withAnimation { proxy.scrollTo(target, anchor: .top) }
        }
        if focusComposer {
            try? await Task.sleep(for: .milliseconds(350))
            composerFocused = true
        }
    }

    // MARK: - Comment count

    private func adjustCommentCount(by delta: Int) { viewModel.adjustCommentCount(by: delta) }

    // MARK: - Comments header

    private func commentsHeader(count: Int) -> some View {
        Text(String(format: bundle.loc("Comments · %d"), count))
            .font(.system(size: 15, weight: .semibold))
            .foregroundColor(AppColors.textPrimary(colorScheme))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, AppSpacing.md)
            .padding(.top, AppSpacing.md)
            .padding(.bottom, AppSpacing.xs)
    }

    // MARK: - Composer

    /// Floating on the grey background — a rounded "Replying to" chip (when
    /// replying) above an avatar + pill field + send row, instead of a
    /// full-width slab with a divider.
    private func composerBar(proxy: ScrollViewProxy) -> some View {
        VStack(spacing: AppSpacing.xs) {
            if let replying = commentVM.replyingTo {
                HStack(spacing: 8) {
                    Image(systemName: "arrowshape.turn.up.left.fill")
                        .font(.system(size: 12))
                        .foregroundColor(themeManager.theme.primary)
                    Text(String(format: bundle.loc("Replying to %@"), replying.author.displayName))
                        .font(.system(size: 13))
                        .foregroundColor(AppColors.textSecondary(colorScheme))
                    Spacer()
                    Button { commentVM.replyingTo = nil } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundColor(AppColors.textSecondary(colorScheme).opacity(0.6))
                    }
                }
                .padding(.horizontal, AppSpacing.md)
                .padding(.vertical, 6)
                .background(themeManager.theme.primary.opacity(0.10), in: Capsule())
                .padding(.horizontal, AppSpacing.sm)
            }

            HStack(spacing: 10) {
                if let me = appState.currentUser {
                    AvatarView(user: me, size: 36)
                }

                TextField(bundle.loc("Write a comment..."), text: $draft, axis: .vertical)
                    .font(.system(size: 15))
                    .lineLimit(4)
                    .focused($composerFocused)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(AppColors.surface(colorScheme), in: Capsule())
                    .overlay(Capsule().stroke(AppColors.borderDefault(colorScheme), lineWidth: 1))

                Button {
                    Task {
                        let text = draft
                        draft = ""
                        let ok = await commentVM.addComment(postId: postId, content: text)
                        if ok { adjustCommentCount(by: 1) }
                        // Reveal the comment/reply just sent — triggered directly
                        // here (not inferred from a comments-count change) so it
                        // can't misfire on the initial load.
                        if ok, let last = commentVM.comments.last {
                            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                } label: {
                    Image(systemName: commentVM.isSending ? "clock" : "paperplane.fill")
                        .font(.system(size: 20))
                        .foregroundColor(draft.trimmingCharacters(in: .whitespaces).isEmpty
                                         ? AppColors.textSecondary(colorScheme) : themeManager.theme.primary)
                }
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || commentVM.isSending)
            }
            .padding(.horizontal, AppSpacing.md)
        }
        .padding(.vertical, AppSpacing.sm)
    }

    // MARK: - Error state

    private var errorState: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.questionmark")
                .font(.system(size: 40))
                .foregroundColor(AppColors.textSecondary(colorScheme).opacity(0.4))
            Text("This post no longer exists or you don't have permission to view it", bundle: bundle)
                .font(.system(size: 15))
                .foregroundColor(AppColors.textSecondary(colorScheme))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .padding(.top, 80)
    }
}

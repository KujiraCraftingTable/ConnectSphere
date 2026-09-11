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

    @State private var post: Post?
    @State private var loadFailed = false
    @State private var commentVM = CommentViewModel()
    @State private var draft = ""
    @FocusState private var composerFocused: Bool

    private let repository = PostRepository()

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
            VStack(spacing: 0) {
                // Pinned header — the post itself never scrolls away; only the
                // comment list below it does. Square corners (cornerRadius: 0)
                // so it reads as a panel at the top of the screen, not a
                // floating card.
                if let post {
                    PostCard(
                        post: post,
                        onPostDeleted: { dismiss() },
                        onPostUpdated: { self.post = $0 },
                        cornerRadius: 0,
                        collapsedTotalHeight: geo.size.height / 4,
                        expandedTotalHeight: geo.size.height / 2
                    )
                    .padding(.top, 8)

                    Divider().padding(.top, 4)
                }

                ScrollViewReader { proxy in
                    ScrollView {
                        if post != nil {
                            CommentsSection(
                                postId: postId,
                                viewModel: commentVM,
                                toastPresenter: toastPresenter,
                                onReplyRequested: { composerFocused = true }
                            )
                        } else if loadFailed {
                            errorState
                        } else {
                            ProgressView().padding(.top, 80)
                        }
                    }
                    // A ScrollView always fills its parent's full proposed height
                    // regardless of content size, so this background covers the
                    // whole comments panel edge-to-edge even with 0-1 comments —
                    // backgrounding CommentsSection itself would only paint its own
                    // (possibly short) content height.
                    .background(AppColors.surface(colorScheme))
                    .task { await loadAll(proxy: proxy) }
                    .onChange(of: commentVM.comments.count) { oldCount, newCount in
                        // A comment you just added → nudge down to it.
                        guard newCount > oldCount, let last = commentVM.comments.last else { return }
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }

                if post != nil {
                    composerBar
                }
            }
        }
        .background(AppColors.base(colorScheme))
        .navigationTitle(bundle.loc("Posts"))
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Load

    private func loadAll(proxy: ScrollViewProxy) async {
        // `.task` re-runs if the view identity is reused for another post id;
        // guard so we don't refetch on every appearance.
        if post == nil && !loadFailed {
            do { post = try await repository.fetchPost(id: postId) }
            catch { loadFailed = true; return }
            await commentVM.load(postId: postId)
        }

        if let target = scrollToCommentId {
            try? await Task.sleep(for: .milliseconds(300))
            withAnimation { proxy.scrollTo(target, anchor: .top) }
        }
        if focusComposer {
            try? await Task.sleep(for: .milliseconds(350))
            composerFocused = true
        }
    }

    // MARK: - Composer

    private var composerBar: some View {
        VStack(spacing: 0) {
            Divider()

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
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(themeManager.theme.primary.opacity(0.06))
            }

            HStack(spacing: 10) {
                if let me = appState.currentUser {
                    AvatarView(user: me, size: 36)
                }

                TextField(bundle.loc("Write a comment..."), text: $draft, axis: .vertical)
                    .font(.system(size: 15))
                    .lineLimit(4)
                    .focused($composerFocused)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(AppColors.base(colorScheme))
                    .clipShape(RoundedRectangle(cornerRadius: 20))

                Button {
                    Task {
                        let text = draft
                        draft = ""
                        let ok = await commentVM.addComment(postId: postId, content: text)
                        if ok, var p = post {
                            // Mirror the Save button: keep the feed cards' count
                            // in sync via a `.postUpdated` broadcast.
                            p.commentCount += 1
                            post = p
                            NotificationCenter.default.post(name: .postUpdated, object: nil, userInfo: ["post": p])
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
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(AppColors.surface(colorScheme))
        }
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

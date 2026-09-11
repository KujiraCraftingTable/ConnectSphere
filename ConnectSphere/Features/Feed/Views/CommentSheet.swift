import SwiftUI

/// Modal comment view — still used by `CommunityPostCard`. The Feed flow no
/// longer presents this; it shows comments inline on the pushed `PostDetailView`
/// instead (see `CommentsSection`, which this sheet also reuses for its list).
struct CommentSheet: View {
    @Environment(AppState.self) var appState
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.appBundle) var bundle
    @Environment(\.colorScheme) var colorScheme
    @State private var viewModel = CommentViewModel()
    @State private var input = ""
    @FocusState private var focused: Bool
    /// Local Undo-toast presenter — `CommentSheet` is a `.sheet`, presented
    /// above `MainTabView`'s app-wide toast overlay, so it can't reuse that one
    /// and owns its own instance instead (see `UndoToastView.swift`).
    @State private var toastPresenter = UndoToastPresenter()

    let postId: String
    let postAuthorId: String
    var onCommentAdded: (() -> Void)?

    var body: some View {
        NavigationStack {
            // ScrollViewReader wraps the whole VStack (not just the list) so
            // the Send button below can also reach `proxy` — it scrolls to a
            // just-sent comment directly, deterministically, rather than
            // inferring "a comment was added" from a comments-count change
            // (that raced against @Observable's deferred change notification
            // and ended up auto-scrolling on the sheet's initial load too).
            ScrollViewReader { proxy in
                VStack(spacing: 0) {
                    // ── Comment list ─────────────────────────────────────────────
                    ScrollView {
                        CommentsSection(
                            postId: postId,
                            postAuthorId: postAuthorId,
                            viewModel: viewModel,
                            toastPresenter: toastPresenter,
                            onReplyRequested: { focused = true }
                        )
                        Color.clear.frame(height: 1).id("bottom")
                    }

                    Divider()

                    // ── Reply banner ────────────────────────────────────────────
                    if let replying = viewModel.replyingTo {
                        HStack(spacing: 8) {
                            Image(systemName: "arrowshape.turn.up.left.fill")
                                .font(.system(size: 12))
                                .foregroundColor(themeManager.theme.primary)
                            Text(String(format: bundle.loc("Replying to %@"), replying.author.displayName))
                                .font(.system(size: 13))
                                .foregroundColor(AppColors.textSecondary(colorScheme))
                            Spacer()
                            Button {
                                viewModel.replyingTo = nil
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 16))
                                    .foregroundColor(AppColors.textSecondary(colorScheme).opacity(0.6))
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(themeManager.theme.primary.opacity(0.06))
                    }

                    // ── Input bar ───────────────────────────────────────────────
                    HStack(spacing: 10) {
                        if let me = appState.currentUser {
                            AvatarView(user: me, size: 36)
                        }

                        TextField(bundle.loc("Write a comment..."), text: $input, axis: .vertical)
                            .font(.system(size: 15))
                            .lineLimit(4)
                            .focused($focused)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(AppColors.base(colorScheme))
                            .clipShape(RoundedRectangle(cornerRadius: 20))

                        Button {
                            Task {
                                let text = input
                                input = ""
                                let ok = await viewModel.addComment(postId: postId, content: text)
                                if ok {
                                    onCommentAdded?()
                                    withAnimation { proxy.scrollTo("bottom") }
                                }
                            }
                        } label: {
                            Image(systemName: viewModel.isSending ? "clock" : "paperplane.fill")
                                .font(.system(size: 20))
                                .foregroundColor(input.trimmingCharacters(in: .whitespaces).isEmpty
                                                 ? AppColors.textSecondary(colorScheme) : themeManager.theme.primary)
                        }
                        .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty || viewModel.isSending)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(AppColors.surface(colorScheme))
                }
                .background(AppColors.base(colorScheme))
                .navigationTitle(bundle.loc("Comments"))
                .navigationBarTitleDisplayMode(.inline)
            }
        }
        .undoToastOverlay(toastPresenter)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .task { await viewModel.load(postId: postId) }
        .onAppear { focused = true }
    }
}

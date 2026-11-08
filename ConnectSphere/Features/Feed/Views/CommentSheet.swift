import SwiftUI

/// Modal comment view, `PostCard`'s fallback when it has no `onOpenDetail`
/// to push to (e.g. from inside `PostDetailView` itself, or before that push
/// wiring existed for a given screen). Feed's main flow shows comments inline
/// on the pushed `PostDetailView` instead (see `CommentsSection`, which this
/// sheet also reuses for its list).
struct CommentSheet: View {
    @Environment(AppState.self) var appState
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.appBundle) var bundle
    @Environment(\.colorScheme) var colorScheme
    @State private var viewModel = CommentViewModel()
    @State private var input = ""
    /// A comment is being edited in place: the composer steps aside.
    @State private var isEditingComment = false
    @FocusState private var focused: Bool
    /// Local Undo-toast presenter, `CommentSheet` is a `.sheet`, presented
    /// above `MainTabView`'s app-wide toast overlay, so it can't reuse that one
    /// and owns its own instance instead (see `UndoToastView.swift`).
    @State private var toastPresenter = UndoToastPresenter()

    let postId: String
    let postAuthorId: String
    /// Called with the change in comment count (+1 on send, -N on delete, +1
    /// on undo), see `CommentsSection.onCommentCountChange`, which this
    /// passes straight through.
    var onCommentCountChange: ((Int) -> Void)?
    /// Opens at full height, e.g. over the full-screen photo viewer.
    var fullHeight = false

    var body: some View {
        NavigationStack {
            // ScrollViewReader wraps the whole VStack (not just the list) so
            // the Send button below can also reach `proxy`. It scrolls to a
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
                            onReplyRequested: { focused = true },
                            onCommentCountChange: { delta in onCommentCountChange?(delta) },
                            onEditingChange: { isEditingComment = $0 }
                        )
                        Color.clear.frame(height: 1).id("bottom")
                    }

                    if !isEditingComment {
                    Divider()

                    // ── Reply banner ────────────────────────────────────────────
                    if let replying = viewModel.replyingTo {
                        HStack(spacing: 8) {
                            Image(systemName: "arrowshape.turn.up.left.fill")
                                .scaledFont(12)
                                .foregroundColor(themeManager.theme.primary)
                            Text(String(format: bundle.loc("Replying to %@"), replying.author.displayName))
                                .scaledFont(13)
                                .foregroundColor(AppColors.textSecondary(colorScheme))
                            Spacer()
                            Button {
                                viewModel.replyingTo = nil
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .scaledFont(16)
                                    .foregroundColor(AppColors.textSecondary(colorScheme).opacity(0.6))
                            }
                            .accessibilityLabel(Bundle.app.loc("Cancel reply"))
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(themeManager.theme.primary.opacity(0.06))
                    }

                    // ── Input bar ───────────────────────────────────────────────
                    HStack(alignment: CommentInputBox.isExpanded(text: input, hasPhoto: viewModel.attachedPhoto != nil)
                               ? .bottom : .center, spacing: 10) {
                        CommentInputBox(text: $input, viewModel: viewModel)
                            .focused($focused)

                        Button {
                            Task {
                                let text = input
                                input = ""
                                let ok = await viewModel.addComment(postId: postId, content: text)
                                if ok {
                                    onCommentCountChange?(1)
                                    withAnimation { proxy.scrollTo("bottom") }
                                }
                            }
                        } label: {
                            Image(systemName: viewModel.isSending ? "clock" : "paperplane.fill")
                                .scaledFont(20)
                                .foregroundColor(viewModel.canSend(input)
                                                 ? themeManager.theme.primary : AppColors.textSecondary(colorScheme))
                        }
                        .accessibilityLabel(Bundle.app.loc("Send"))
                        // Level with the camera, which sits above the taller box's bottom edge.
                        .padding(.bottom, CommentInputBox.isExpanded(text: input, hasPhoto: viewModel.attachedPhoto != nil) ? 12 : 0)
                        .disabled(!viewModel.canSend(input))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(AppColors.surface(colorScheme))
                    }
                }
                // White like the post view's comment card, so the grey bubbles show.
                .background(AppColors.surface(colorScheme))
                .navigationTitle(bundle.loc("Comments"))
                .navigationBarTitleDisplayMode(.inline)
            }
        }
        .confirmBeforePosting(viewModel, text: $input) { onCommentCountChange?(1) }
        .undoToastOverlay(toastPresenter)
        .presentationDetents(fullHeight ? [.large] : [.medium, .large])
        .presentationDragIndicator(.visible)
        .task { await viewModel.load(postId: postId) }
        .onAppear { focused = true }
    }
}

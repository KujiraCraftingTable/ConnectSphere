import SwiftUI

/// The comment list + inline reply/edit/delete, extracted from the old
/// `CommentSheet` so it can render inline on the pushed `PostDetailView`
/// (comments below the post) as well as inside `CommentSheet` (still used by
/// `CommunityPostCard`). It renders *only* the list — the composer / reply
/// banner live with whoever hosts it, so the host can pin them outside the
/// scroll view and own the keyboard focus.
///
/// `viewModel` and `toastPresenter` are passed in rather than owned: the host
/// shares its view model with its own pinned composer, and picks the toast
/// presenter that its context can actually display (the app-wide one on a
/// pushed screen, a private one inside a `.sheet`).
struct CommentsSection: View {
    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.appBundle) private var bundle
    @Environment(\.colorScheme) private var colorScheme

    let postId: String
    /// The post's own author — compared against each comment's author to show
    /// the "Author" badge on their comments/replies.
    let postAuthorId: String
    let viewModel: CommentViewModel
    let toastPresenter: UndoToastPresenter
    /// Called after `viewModel.replyingTo` is set, so the host can focus its composer.
    var onReplyRequested: () -> Void = {}
    /// Called with the change in total comment count whenever this section's
    /// own actions move it — `+1` after sending a comment/reply, `-N` after
    /// a delete (N = however many were actually removed, including any
    /// replies cascaded with a root), `+1` after undoing a delete. Lets the
    /// host (which owns the visible comment count) update immediately
    /// instead of waiting on a full refetch — the server's own count is
    /// already updated durably and remains the eventual source of truth.
    var onCommentCountChange: (Int) -> Void = { _ in }

    @State private var pendingDeleteCommentId: String? = nil
    @State private var editingCommentId: String? = nil
    @State private var editingText: String = ""


    var body: some View {
        Group {
            if viewModel.isLoading && viewModel.comments.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
            } else if viewModel.comments.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "bubble.left").font(.system(size: 40))
                        .foregroundColor(AppColors.textSecondary(colorScheme).opacity(0.4))
                    Text("No comments yet", bundle: bundle)
                        .font(.system(size: 15))
                        .foregroundColor(AppColors.textSecondary(colorScheme))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    sortControl
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(viewModel.parents) { comment in
                            commentBlock(comment)
                        }
                    }
                }
                .padding(.top, 8)
            }
        }
        .alert(
            bundle.loc("Delete comment?"),
            isPresented: Binding(
                get: { pendingDeleteCommentId != nil },
                set: { if !$0 { pendingDeleteCommentId = nil } }
            )
        ) {
            Button(bundle.loc("Delete"), role: .destructive) {
                if let id = pendingDeleteCommentId {
                    pendingDeleteCommentId = nil
                    Task { await handleDeleteComment(commentId: id) }
                }
            }
            Button(bundle.loc("Cancel"), role: .cancel) {}
        } message: {
            Text("This comment won't be shown in the app. You can restore it from Recently Deleted within 30 days.", bundle: bundle)
        }
    }

    // MARK: - Sort control

    private var sortControl: some View {
        HStack {
            Menu {
                ForEach(CommentSortOrder.allCases) { order in
                    Button {
                        viewModel.sortOrder = order
                    } label: {
                        if viewModel.sortOrder == order {
                            Label(sortOrderLabel(order), systemImage: "checkmark")
                        } else {
                            Text(sortOrderLabel(order))
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(sortOrderLabel(viewModel.sortOrder))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                }
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(AppColors.textSecondary(colorScheme))
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }

    private func sortOrderLabel(_ order: CommentSortOrder) -> String {
        switch order {
        case .oldest: return bundle.loc("Oldest first")
        case .newest: return bundle.loc("Newest first")
        }
    }

    // MARK: - Delete comment (with Undo toast)

    /// Deletes the comment then shows an Undo toast; tapping Undo calls restore
    /// then reloads the whole comment list.
    private func handleDeleteComment(commentId: String) async {
        let removed = await viewModel.deleteComment(postId: postId, commentId: commentId)
        if removed > 0 { onCommentCountChange(-removed) }
        toastPresenter.show(message: bundle.loc("Comment deleted")) {
            Task {
                // Restore only ever brings back the single deleted comment,
                // never its cascade-deleted replies — so the delta is always
                // exactly +1, however much `removed` subtracted above.
                if await viewModel.restoreComment(postId: postId, commentId: commentId) { onCommentCountChange(1) }
            }
        }
    }

    // MARK: - Comment block (root + indented replies)

    /// A thread is three levels deep: comment → reply → reply-to-reply. A reply
    /// to a third-level reply is stored beside it (the server places it under
    /// the same parent), so every row can be replied to and the tree never
    /// grows a fourth level. Every reply says who it answers.
    @ViewBuilder
    private func commentBlock(_ comment: CommentDTO) -> some View {
        let replies = viewModel.replies(for: comment.id)
        let subReplies = replies.map { viewModel.replies(for: $0.id) }
        let lines = ThreadDecoration.layout(replyCounts: subReplies.map(\.count))
        let lineColor = AppColors.borderDefault(colorScheme)

        row(comment, level: 0, answering: nil)
            .threadLines(lines.root, level: 0, color: lineColor)

        ForEach(Array(replies.enumerated()), id: \.element.id) { index, reply in
            row(reply, level: 1, answering: comment)
                .threadLines(lines.replies[index].0, level: 1, color: lineColor)

            ForEach(Array(subReplies[index].enumerated()), id: \.element.id) { subIndex, subReply in
                row(subReply, level: 2, answering: reply)
                    .threadLines(lines.replies[index].1[subIndex], level: 2, color: lineColor)
            }
        }
    }

    /// One row at `level` (0–2), indented to match the thread lines.
    /// `answering` is the comment it sits under — the fallback for "replied
    /// to" when the server didn't say (replies written before it recorded it).
    private func row(_ comment: CommentDTO, level: Int, answering parent: CommentDTO?) -> some View {
        Group {
            if viewModel.isCollapsed(comment) {
                mutedRow(comment)
            } else {
                commentRow(comment, answering: parent)
            }
        }
        .id(comment.id)
        .padding(.leading, CGFloat(level) * ThreadLinesShape.indentStep)
    }

    /// Stands in for a comment containing a muted word: it keeps its place
    /// (and the thread lines) but not its text, until the user asks.
    private func mutedRow(_ comment: CommentDTO) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "speaker.slash")
                .font(.system(size: 12))
            Text("Hidden: contains a word you muted", bundle: bundle)
                .font(.system(size: 13))
            Text("·")
            Button { withAnimation(.snappy) { viewModel.reveal(comment.id) } } label: {
                Text("Show", bundle: bundle).font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundColor(themeManager.theme.primary)
            Spacer(minLength: 0)
        }
        .foregroundColor(AppColors.textTertiary(colorScheme))
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func commentRow(_ comment: CommentDTO, answering parent: CommentDTO?) -> some View {
        let target = comment.replyTo.map { CommentReplyTarget(name: $0.displayName, userId: $0.id) }
            ?? parent.map { CommentReplyTarget(name: $0.author.displayName, userId: $0.author.id) }
        return CommentRow(
            comment: comment,
            isOwn: comment.author.id == appState.currentUser?.id,
            isPostAuthor: comment.author.id == postAuthorId,
            isEditing: editingCommentId == comment.id,
            editingText: $editingText,
            replyTarget: target,
            onLike:   { Task { await viewModel.toggleLike(postId: postId, commentId: comment.id) } },
            onReply:  {
                viewModel.replyingTo = comment
                onReplyRequested()
            },
            onDelete: { pendingDeleteCommentId = comment.id },
            onEdit: { beginEditing(comment) },
            onSaveEdit: { Task { await saveEdit(commentId: comment.id) } },
            onCancelEdit: { editingCommentId = nil }
        )
    }

    // MARK: - Edit comment (inline)

    private func beginEditing(_ comment: CommentDTO) {
        editingCommentId = comment.id
        editingText = comment.content
    }

    private func saveEdit(commentId: String) async {
        let text = editingText
        let ok = await viewModel.updateComment(postId: postId, commentId: commentId, content: text)
        if ok { editingCommentId = nil }
    }
}

// MARK: - Comment Row

/// The person a reply is answering, spelled out as "[replier] replied to
/// [name]" — the indent alone can't say which of several siblings a reply
/// addresses. Paired name+id (not a bare `String?`) so the attribution text
/// and its `NavigationLink` destination can never drift apart.
struct CommentReplyTarget {
    let name: String
    let userId: String
}

struct CommentRow: View {
    /// Row geometry shared with `ThreadLinesShape`, which draws to the avatar.
    static let avatarSize: CGFloat = 36
    static let horizontalInset: CGFloat = 12
    static let verticalInset: CGFloat = 6

    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.appBundle) var bundle
    @Environment(\.colorScheme) var colorScheme

    let comment: CommentDTO
    var isOwn: Bool = false
    /// True when this comment/reply was written by the post's own author —
    /// shows a small "Author" badge to the left of the timestamp, so other
    /// readers can quickly spot the poster's own comments.
    var isPostAuthor: Bool = false
    /// True while this specific row is the one being edited inline.
    var isEditing: Bool = false
    /// Shared editing-text binding, owned by the host — only meaningful while
    /// `isEditing` is true.
    var editingText: Binding<String> = .constant("")
    /// Set on every reply — renders "replied to [name]" after this row's own
    /// name, both independently tappable to their own profiles.
    var replyTarget: CommentReplyTarget? = nil
    var onLike:   (() -> Void)? = nil
    var onReply:  (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil
    var onEdit:   (() -> Void)? = nil
    var onSaveEdit:   (() -> Void)? = nil
    var onCancelEdit: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            avatar

            VStack(alignment: .leading, spacing: 4) {
                if isEditing {
                    editRow
                } else {
                    bubble
                        .contextMenu {
                            if isOwn, let onEdit {
                                Button(action: onEdit) {
                                    Label(bundle.loc("Edit comment"), systemImage: "pencil")
                                }
                            }
                            if isOwn, let onDelete {
                                Button(role: .destructive, action: onDelete) {
                                    Label(bundle.loc("Delete comment"), systemImage: "trash")
                                }
                            }
                        }
                }
                metaRow
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, Self.horizontalInset)
        .padding(.vertical, Self.verticalInset)
    }

    /// Name line + text in a rounded bubble that hugs its content
    /// (Messenger/Facebook style, like the chat screen's bubbles). The grey
    /// `base` fill stands out on the white comments card in both modes.
    private var bubble: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                NavigationLink(destination: UserProfileView(userId: comment.author.id).environment(appState)) {
                    Text(comment.author.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(AppColors.textPrimary(colorScheme))
                }
                .buttonStyle(.plain)

                // Right beside the name it describes — after "replied to X"
                // it read as if X were the post's author.
                if isPostAuthor {
                    Text("Author", bundle: bundle)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(themeManager.theme.primary)
                        .clipShape(Capsule())
                }

                if let replyTarget {
                    Text("replied to", bundle: bundle)
                        .font(.system(size: 13))
                        .foregroundColor(AppColors.textSecondary(colorScheme))
                    NavigationLink(destination: UserProfileView(userId: replyTarget.userId).environment(appState)) {
                        Text(replyTarget.name)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(AppColors.textPrimary(colorScheme))
                    }
                    .buttonStyle(.plain)
                }
            }

            Text(comment.content)
                .font(.system(size: 14))
                .foregroundColor(AppColors.textPrimary(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(AppColors.base(colorScheme), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    /// Time · like · Reply under the bubble, inset to line up with its text.
    private var metaRow: some View {
        HStack(spacing: 14) {
            Text(comment.createdAt.timeAgoString)
                .font(.system(size: 12))
                .foregroundColor(AppColors.textSecondary(colorScheme))

            if let onLike {
                Button(action: onLike) {
                    HStack(spacing: 3) {
                        Image(systemName: comment.isLiked ? "heart.fill" : "heart")
                            .font(.system(size: 12))
                        if comment.likeCount > 0 {
                            Text("\(comment.likeCount)").font(.system(size: 12))
                        }
                    }
                    .foregroundColor(comment.isLiked ? AppColors.danger(colorScheme) : AppColors.textSecondary(colorScheme))
                }
                .buttonStyle(.plain)
            }
            if let onReply {
                Button(action: onReply) {
                    Text("Reply", bundle: bundle)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(AppColors.textSecondary(colorScheme))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.leading, 12)
    }

    /// Compact inline edit UI — replaces the static content `Text` while
    /// `isEditing` is true. Single-line-ish; not a full-screen composer.
    private var editRow: some View {
        HStack(spacing: 8) {
            TextField(bundle.loc("Write a comment..."), text: editingText, axis: .vertical)
                .font(.system(size: 14))
                .lineLimit(4)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(AppColors.base(colorScheme))
                .clipShape(RoundedRectangle(cornerRadius: 12))

            Button(action: { onSaveEdit?() }) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundColor(themeManager.theme.primary)
            }
            .disabled(editingText.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty)

            Button(action: { onCancelEdit?() }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundColor(AppColors.textSecondary(colorScheme))
            }
        }
    }

    @ViewBuilder
    private var avatar: some View {
        if let urlString = comment.author.avatarUrl, let url = URL(string: urlString) {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    initialCircle
                }
            }
            .frame(width: Self.avatarSize, height: Self.avatarSize)
            .clipShape(Circle())
        } else {
            initialCircle
        }
    }

    private var initialCircle: some View {
        ZStack {
            Circle()
                .fill(Color(hex: comment.author.avatarColor))
                .frame(width: Self.avatarSize, height: Self.avatarSize)
            Text(String(comment.author.displayName.prefix(1)).uppercased())
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.white)
        }
    }
}

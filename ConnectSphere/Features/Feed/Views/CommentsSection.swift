import SwiftUI
import Observation

@MainActor
@Observable
class CommentViewModel {
    var comments: [CommentDTO] = []
    var isLoading  = false
    var isSending  = false
    /// Comment currently being replied to (nil = a plain comment) — can be a
    /// root comment or a depth-1 reply (replies nest one level deeper: root →
    /// reply → reply-to-reply, capped there).
    var replyingTo: CommentDTO? = nil

    private let repository = PostRepository()

    private func authToken() -> String? {
        KeychainHelper.load(forKey: KeychainHelper.tokenKey)
    }

    /// Root comments, in chronological order
    var parents: [CommentDTO] {
        comments.filter { $0.parentCommentId == nil }
    }

    /// Replies to a given root comment
    func replies(for parentId: String) -> [CommentDTO] {
        comments.filter { $0.parentCommentId == parentId }
    }

    func load(postId: String) async {
        isLoading = true
        if let res = try? await APIClient.shared.fetch(CommentsResponse.self,
                                                       from: .listComments(postId: postId)) {
            comments = res.data
        }
        isLoading = false
    }

    /// Posts a comment (or a reply, when `replyingTo` is set). Routes through
    /// `PostRepository` like every other post API call; reloads the whole list
    /// on success to guarantee an accurate sync.
    func addComment(postId: String, content: String) async -> Bool {
        let trimmed = content.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        isSending = true
        defer { isSending = false }

        let parentId = replyingTo?.id
        guard (try? await repository.addComment(postId: postId, content: trimmed, parentCommentId: parentId)) != nil else {
            return false
        }
        replyingTo = nil
        await load(postId: postId)
        return true
    }

    /// Deletes one of your own comments (or one on your own post) — backend soft-deletes replies too
    func deleteComment(postId: String, commentId: String) async {
        guard let token = authToken() else { return }
        struct Empty: Decodable { let status: String? }
        _ = try? await NetworkClient.shared.fetch(
            Empty.self,
            path: "/posts/\(postId)/comments/\(commentId)",
            method: "DELETE",
            token: token
        )
        await load(postId: postId)
    }

    /// Edits the content of one of your own comments. Same approach as
    /// addComment/deleteComment: reload the whole comment list on success
    /// (simpler than patching it in place).
    func updateComment(postId: String, commentId: String, content: String) async -> Bool {
        let trimmed = content.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        guard (try? await repository.updateComment(postId: postId, commentId: commentId, content: trimmed)) != nil else {
            return false
        }
        await load(postId: postId)
        return true
    }

    /// Toggles a like on a comment; updates in place from the response
    func toggleLike(postId: String, commentId: String) async {
        guard let token = authToken() else { return }
        guard let res = try? await NetworkClient.shared.fetch(
            LikeResponse.self,
            path: "/posts/\(postId)/comments/\(commentId)/like",
            method: "POST",
            token: token
        ) else { return }

        if let i = comments.firstIndex(where: { $0.id == commentId }) {
            comments[i].isLiked   = res.liked
            comments[i].likeCount = res.likeCount
        }
    }
}

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
    @Environment(\.appBundle) private var bundle
    @Environment(\.colorScheme) private var colorScheme

    let postId: String
    let viewModel: CommentViewModel
    let toastPresenter: UndoToastPresenter
    /// Called after `viewModel.replyingTo` is set, so the host can focus its composer.
    var onReplyRequested: () -> Void = {}

    @State private var pendingDeleteCommentId: String? = nil
    @State private var editingCommentId: String? = nil
    @State private var editingText: String = ""

    private let repository = PostRepository()

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
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(viewModel.parents) { comment in
                        commentBlock(comment)
                        Divider().padding(.leading, 56)
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

    // MARK: - Delete comment (with Undo toast)

    /// Deletes the comment then shows an Undo toast; tapping Undo calls restore
    /// then reloads the whole comment list.
    private func handleDeleteComment(commentId: String) async {
        await viewModel.deleteComment(postId: postId, commentId: commentId)
        toastPresenter.show(message: bundle.loc("Comment deleted")) {
            Task {
                try? await repository.restoreComment(postId: postId, commentId: commentId)
                await viewModel.load(postId: postId)
            }
        }
    }

    // MARK: - Comment block (root + indented replies)

    @ViewBuilder
    private func commentBlock(_ comment: CommentDTO) -> some View {
        CommentRow(
            comment: comment,
            isOwn: comment.author.id == appState.currentUser?.id,
            isEditing: editingCommentId == comment.id,
            editingText: $editingText,
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
        .id(comment.id)

        ForEach(viewModel.replies(for: comment.id)) { reply in
            CommentRow(
                comment: reply,
                isOwn: reply.author.id == appState.currentUser?.id,
                isEditing: editingCommentId == reply.id,
                editingText: $editingText,
                onLike:   { Task { await viewModel.toggleLike(postId: postId, commentId: reply.id) } },
                onReply:  {
                    // A reply to a reply nests one level deeper (staircase
                    // indent below) — the backend caps depth at 2.
                    viewModel.replyingTo = reply
                    onReplyRequested()
                },
                onDelete: { pendingDeleteCommentId = reply.id },
                onEdit: { beginEditing(reply) },
                onSaveEdit: { Task { await saveEdit(commentId: reply.id) } },
                onCancelEdit: { editingCommentId = nil }
            )
            .id(reply.id)
            .padding(.leading, 44)

            ForEach(viewModel.replies(for: reply.id)) { subReply in
                CommentRow(
                    comment: subReply,
                    isOwn: subReply.author.id == appState.currentUser?.id,
                    isEditing: editingCommentId == subReply.id,
                    editingText: $editingText,
                    replyTarget: CommentReplyTarget(name: reply.author.displayName, userId: reply.author.id),
                    onLike:   { Task { await viewModel.toggleLike(postId: postId, commentId: subReply.id) } },
                    onReply:  nil,   // max depth reached — can't reply to a reply-of-a-reply
                    onDelete: { pendingDeleteCommentId = subReply.id },
                    onEdit: { beginEditing(subReply) },
                    onSaveEdit: { Task { await saveEdit(commentId: subReply.id) } },
                    onCancelEdit: { editingCommentId = nil }
                )
                .id(subReply.id)
                .padding(.leading, 88)
            }
        }
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

/// The person a depth-2 reply is answering — a depth-1 comment can have
/// several depth-2 replies, and the shared indent alone doesn't say which one
/// they're addressing, so the row spells it out as "[replier] replied to
/// [name]". Paired name+id (not a bare `String?`) so the attribution text and
/// its `NavigationLink` destination can never drift apart.
struct CommentReplyTarget {
    let name: String
    let userId: String
}

struct CommentRow: View {
    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.appBundle) var bundle
    @Environment(\.colorScheme) var colorScheme

    let comment: CommentDTO
    var isOwn: Bool = false
    /// True while this specific row is the one being edited inline.
    var isEditing: Bool = false
    /// Shared editing-text binding, owned by the host — only meaningful while
    /// `isEditing` is true.
    var editingText: Binding<String> = .constant("")
    /// Set only on a depth-2 reply (a reply to a reply) — renders "replied to
    /// [name]" after this row's own name, both independently tappable to their
    /// own profiles.
    var replyTarget: CommentReplyTarget? = nil
    var onLike:   (() -> Void)? = nil
    var onReply:  (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil
    var onEdit:   (() -> Void)? = nil
    var onSaveEdit:   (() -> Void)? = nil
    var onCancelEdit: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            avatar

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    NavigationLink(destination: UserProfileView(userId: comment.author.id).environment(appState)) {
                        Text(comment.author.displayName)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(AppColors.textPrimary(colorScheme))
                    }
                    .buttonStyle(.plain)

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

                    Text(comment.createdAt.timeAgoString)
                        .font(.system(size: 12))
                        .foregroundColor(AppColors.textSecondary(colorScheme))
                }

                if isEditing {
                    editRow
                } else {
                    Text(comment.content)
                        .font(.system(size: 14))
                        .foregroundColor(AppColors.textPrimary(colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                }

                // Action row: like + reply
                HStack(spacing: 16) {
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
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(AppColors.textSecondary(colorScheme))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 2)
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
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
            .frame(width: 36, height: 36)
            .clipShape(Circle())
        } else {
            initialCircle
        }
    }

    private var initialCircle: some View {
        ZStack {
            Circle()
                .fill(Color(hex: comment.author.avatarColor))
                .frame(width: 36, height: 36)
            Text(String(comment.author.displayName.prefix(1)).uppercased())
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.white)
        }
    }
}

import SwiftUI
import Combine
import Observation

@MainActor
@Observable
class CommentViewModel {
    var comments: [CommentDTO] = []
    var isLoading  = false
    var isSending  = false
    /// Root comment currently being replied to (nil = a plain comment)
    var replyingTo: CommentDTO? = nil

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

    func addComment(postId: String, content: String) async -> Bool {
        let trimmed = content.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        guard let token = authToken() else { return false }
        isSending = true
        defer { isSending = false }

        guard let url = URL(string: APIConfig.baseURL + "/posts/\(postId)/comments") else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        var body: [String: Any] = ["content": trimmed]
        if let parent = replyingTo { body["parent_comment_id"] = parent.id }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        guard let (_, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse,
              http.statusCode == 201 else { return false }

        replyingTo = nil
        // Reload the whole comment list to guarantee an accurate sync
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
        let repository = PostRepository()
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

struct CommentSheet: View {
    @Environment(AppState.self) var appState
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.appBundle) var bundle
    @State private var viewModel = CommentViewModel()
    @Environment(\.colorScheme) var colorScheme
    @State private var input = ""
    @FocusState private var focused: Bool
    /// Local Undo-toast presenter — CommentSheet is a `.sheet`, presented above
    /// `MainTabView`'s app-wide toast overlay, so it can't reuse that one and
    /// owns its own instance instead (see `UndoToastView.swift`).
    @State private var toastPresenter = UndoToastPresenter()
    /// Comment (or reply) awaiting delete confirmation — tracks the specific
    /// id since this is a list, not a single toggle, mirroring
    /// `ChatPinnedMessagesView.swift`'s `pendingUnpin` pattern.
    @State private var pendingDeleteCommentId: String? = nil
    /// Comment (or reply) currently being edited inline — id of the row whose
    /// static text is swapped for an editable field, plus the in-progress text.
    @State private var editingCommentId: String? = nil
    @State private var editingText: String = ""
    private let repository = PostRepository()

    let postId: String
    var onCommentAdded: (() -> Void)?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // ── Comment list ──────────────────────────────────────────────
                if viewModel.isLoading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if viewModel.comments.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "bubble.left").font(.system(size: 40))
                            .foregroundColor(AppColors.textSecondary(colorScheme).opacity(0.4))
                        Text("No comments yet", bundle: bundle)
                            .font(.system(size: 15))
                            .foregroundColor(AppColors.textSecondary(colorScheme))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(viewModel.parents) { comment in
                                    commentBlock(comment)
                                    Divider().padding(.leading, 56)
                                }
                            }
                            .padding(.top, 8)
                            Color.clear.frame(height: 1).id("bottom")
                        }
                        .onChange(of: viewModel.comments.count) { _, _ in
                            withAnimation { proxy.scrollTo("bottom") }
                        }
                    }
                }

                Divider()

                // ── Reply banner ─────────────────────────────────────────────
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

                // ── Input bar ─────────────────────────────────────────────────
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
                            if ok { onCommentAdded?() }
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
        .undoToastOverlay(toastPresenter)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .task { await viewModel.load(postId: postId) }
        .onAppear { focused = true }
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
    /// then reloads the whole comment list — the same approach `addComment`/
    /// `deleteComment` already use (full reload to guarantee sync), simpler
    /// than patching it in place.
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
                focused = true
            },
            onDelete: { pendingDeleteCommentId = comment.id },
            onEdit: { beginEditing(comment) },
            onSaveEdit: { Task { await saveEdit(commentId: comment.id) } },
            onCancelEdit: { editingCommentId = nil }
        )

        ForEach(viewModel.replies(for: comment.id)) { reply in
            CommentRow(
                comment: reply,
                isOwn: reply.author.id == appState.currentUser?.id,
                isEditing: editingCommentId == reply.id,
                editingText: $editingText,
                onLike:   { Task { await viewModel.toggleLike(postId: postId, commentId: reply.id) } },
                onReply:  nil,   // only one level of replies
                onDelete: { pendingDeleteCommentId = reply.id },
                onEdit: { beginEditing(reply) },
                onSaveEdit: { Task { await saveEdit(commentId: reply.id) } },
                onCancelEdit: { editingCommentId = nil }
            )
            .padding(.leading, 44)
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

struct CommentRow: View {
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.appBundle) var bundle
    @Environment(\.colorScheme) var colorScheme

    let comment: CommentDTO
    var isOwn: Bool = false
    /// True while this specific row is the one being edited inline.
    var isEditing: Bool = false
    /// Shared editing-text binding, owned by `CommentSheet` — only meaningful
    /// while `isEditing` is true.
    var editingText: Binding<String> = .constant("")
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
                HStack(spacing: 6) {
                    Text(comment.author.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(AppColors.textPrimary(colorScheme))
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
                            .foregroundColor(comment.isLiked ? .red : AppColors.textSecondary(colorScheme))
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

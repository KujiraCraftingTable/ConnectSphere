import SwiftUI
import Combine
import Observation

@MainActor
@Observable
class CommentViewModel {
    var comments: [CommentDTO] = []
    var isLoading  = false
    var isSending  = false
    /// Comment gốc đang được trả lời (nil = comment thường)
    var replyingTo: CommentDTO? = nil

    private func authToken() -> String? {
        KeychainHelper.load(forKey: KeychainHelper.tokenKey)
    }

    /// Comment gốc, theo thứ tự thời gian
    var parents: [CommentDTO] {
        comments.filter { $0.parentCommentId == nil }
    }

    /// Replies của một comment gốc
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
        // Reload toàn bộ comments để đảm bảo sync chính xác
        await load(postId: postId)
        return true
    }

    /// Xóa comment của mình (hoặc trên bài của mình) — backend soft-delete cả replies
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

    /// Toggle like một comment; cập nhật tại chỗ từ response
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
                        Text("Chưa có bình luận nào", bundle: bundle)
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
                        Text(String(format: bundle.loc("Đang trả lời %@"), replying.author.displayName))
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

                    TextField(bundle.loc("Viết bình luận..."), text: $input, axis: .vertical)
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
            .navigationTitle(bundle.loc("Bình luận"))
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .task { await viewModel.load(postId: postId) }
        .onAppear { focused = true }
    }

    // MARK: - Comment block (gốc + replies thụt lề)

    @ViewBuilder
    private func commentBlock(_ comment: CommentDTO) -> some View {
        CommentRow(
            comment: comment,
            isOwn: comment.author.id == appState.currentUser?.id,
            onLike:   { Task { await viewModel.toggleLike(postId: postId, commentId: comment.id) } },
            onReply:  {
                viewModel.replyingTo = comment
                focused = true
            },
            onDelete: { Task { await viewModel.deleteComment(postId: postId, commentId: comment.id) } }
        )

        ForEach(viewModel.replies(for: comment.id)) { reply in
            CommentRow(
                comment: reply,
                isOwn: reply.author.id == appState.currentUser?.id,
                onLike:   { Task { await viewModel.toggleLike(postId: postId, commentId: reply.id) } },
                onReply:  nil,   // chỉ reply 1 tầng
                onDelete: { Task { await viewModel.deleteComment(postId: postId, commentId: reply.id) } }
            )
            .padding(.leading, 44)
        }
    }
}

// MARK: - Comment Row

struct CommentRow: View {
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.appBundle) var bundle
    @Environment(\.colorScheme) var colorScheme

    let comment: CommentDTO
    var isOwn: Bool = false
    var onLike:   (() -> Void)? = nil
    var onReply:  (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil

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
                Text(comment.content)
                    .font(.system(size: 14))
                    .foregroundColor(AppColors.textPrimary(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)

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
                            Text("Trả lời", bundle: bundle)
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
            if isOwn, let onDelete {
                Button(role: .destructive, action: onDelete) {
                    Label(bundle.loc("Xóa bình luận"), systemImage: "trash")
                }
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

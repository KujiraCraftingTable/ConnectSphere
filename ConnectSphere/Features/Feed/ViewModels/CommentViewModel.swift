import Foundation
import Observation
import PhotosUI
import SwiftUI

/// How root comments are ordered. Only affects top-level comments. Each
/// root's own replies always stay chronological underneath it, same as a
/// real conversation thread. A third `.mostRelated` case (relevance-ranked)
/// is a natural later addition. Deliberately not built yet, since defining
/// and testing "relevance" well is its own piece of work.
enum CommentSortOrder: String, CaseIterable, Identifiable {
    case oldest
    case newest
    var id: String { rawValue }
}

@MainActor
@Observable
class CommentViewModel {
    var comments: [CommentDTO] = []
    var isLoading  = false
    var isSending  = false
    /// Comment currently being replied to (nil = a plain comment). Can be a
    /// root comment or a depth-1 reply (replies nest one level deeper: root →
    /// reply → reply-to-reply, capped there).
    var replyingTo: CommentDTO? = nil
    /// How `parents` orders root comments. Purely a display concern, doesn't
    /// change what's fetched, so switching it never needs a reload.
    var sortOrder: CommentSortOrder = .oldest
    /// The photo picked for the next comment, shown above the field until sent.
    private(set) var attachedPhoto: UIImage?
    private var attachedPhotoData: Data?

    private let repository = PostRepository()

    /// Muted comments the user chose to show anyway (this screen only).
    private(set) var revealed: Set<String> = []

    func isCollapsed(_ comment: CommentDTO) -> Bool {
        comment.muted && !revealed.contains(comment.id)
    }

    func reveal(_ commentId: String) { revealed.insert(commentId) }

    private func authToken() -> String? {
        KeychainHelper.load(forKey: KeychainHelper.tokenKey)
    }

    /// Root comments, ordered per `sortOrder`.
    var parents: [CommentDTO] {
        let roots = comments.filter { $0.parentCommentId == nil }
        switch sortOrder {
        case .oldest: return roots.sorted { $0.createdAt < $1.createdAt }
        case .newest: return roots.sorted { $0.createdAt > $1.createdAt }
        }
    }

    /// Replies to a given root comment
    func replies(for parentId: String) -> [CommentDTO] {
        comments.filter { $0.parentCommentId == parentId }
    }

    /// Every comment, a page at a time. Sorting and threading happen here,
    /// so a post past one page needs them all (it used to stop at 50).
    static let pageSize = 100
    static let maxPages = 20

    func load(postId: String) async {
        isLoading = true
        defer { isLoading = false }
        var all: [CommentDTO] = []
        for page in 0..<Self.maxPages {
            guard let res = try? await APIClient.shared.fetch(
                CommentsResponse.self,
                from: .listComments(postId: postId, limit: Self.pageSize, offset: page * Self.pageSize))
            else {
                if page == 0 { return }   // keep what's shown when the first page fails
                break
            }
            all += res.data
            if res.data.count < Self.pageSize || all.count >= res.total { break }
        }
        comments = all
    }

    /// Loads a photo picked from the library into the composer (one per comment;
    /// a new pick replaces it).
    func attachPhoto(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data) else { return }
        attachedPhotoData = data
        attachedPhoto = image
    }

    func removePhoto() {
        attachedPhoto = nil
        attachedPhotoData = nil
    }

    /// Whether Send is available: some text, a photo, or both.
    func canSend(_ text: String) -> Bool {
        !isSending && (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || attachedPhoto != nil)
    }

    /// Posts a comment (or a reply, when `replyingTo` is set), uploading the
    /// attached photo first. The server's copy of the new comment goes
    /// straight into the list. No reload of every page.
    func addComment(postId: String, content: String) async -> Bool {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || attachedPhotoData != nil else { return false }
        isSending = true
        defer { isSending = false }

        var imageUrl: String? = nil
        if let attachedPhotoData {
            // Metadata (location, camera) is stripped in uploadImage.
            guard let url = try? await repository.uploadImage(attachedPhotoData) else { return false }
            imageUrl = url
        }
        let parentId = replyingTo?.id
        guard let created = try? await repository.addComment(postId: postId, content: trimmed, parentCommentId: parentId,
                                                              imageUrl: imageUrl) else {
            return false
        }
        comments.append(created)
        replyingTo = nil
        removePhoto()
        return true
    }

    /// Deletes one of your own comments (or one on your own post). Backend
    /// soft-deletes replies too. Returns how many comments were actually
    /// removed (deleting a root cascades to its replies), so the caller can
    /// decrement the post's displayed comment count by the right amount;
    /// `0` if the request failed (nothing was actually removed).
    func deleteComment(postId: String, commentId: String) async -> Int {
        guard let token = authToken() else { return 0 }
        struct Response: Decodable { let removed: Int }
        let removed = (try? await NetworkClient.shared.fetch(
            Response.self,
            path: "/posts/\(postId)/comments/\(commentId)",
            method: "DELETE",
            token: token
        ))?.removed ?? 0
        await load(postId: postId)
        return removed
    }

    /// Edits the content of one of your own comments. Same approach as
    /// addComment/deleteComment: reload the whole comment list on success
    /// (simpler than patching it in place).
    func updateComment(postId: String, commentId: String, content: String) async -> Bool {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        // Editing changes the text only; a comment with a photo may lose it.
        let hasPhoto = comments.first { $0.id == commentId }?.imageUrl != nil
        guard !trimmed.isEmpty || hasPhoto else { return false }
        guard (try? await repository.updateComment(postId: postId, commentId: commentId, content: trimmed)) != nil else {
            return false
        }
        await load(postId: postId)
        return true
    }

    /// Toggles a like on a comment: flips at once, then takes the server's
    /// count, or flips back if the request fails.
    func toggleLike(postId: String, commentId: String) async {
        guard let token = authToken(), let i = comments.firstIndex(where: { $0.id == commentId }) else { return }
        let before = (comments[i].isLiked, comments[i].likeCount)
        comments[i].isLiked.toggle()
        comments[i].likeCount += comments[i].isLiked ? 1 : -1
        let res = try? await NetworkClient.shared.fetch(
            LikeResponse.self,
            path: "/posts/\(postId)/comments/\(commentId)/like",
            method: "POST",
            token: token
        )
        guard let j = comments.firstIndex(where: { $0.id == commentId }) else { return }
        if let res {
            comments[j].isLiked   = res.liked
            comments[j].likeCount = res.likeCount
        } else {
            (comments[j].isLiked, comments[j].likeCount) = before
        }
    }

    /// Undo of a delete: brings back that one comment (never its
    /// cascade-deleted replies), then reloads the list.
    func restoreComment(postId: String, commentId: String) async -> Bool {
        let restored = (try? await repository.restoreComment(postId: postId, commentId: commentId)) != nil
        await load(postId: postId)
        return restored
    }
}

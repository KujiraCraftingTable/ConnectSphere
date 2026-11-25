import Foundation
import Observation
import PhotosUI
import SwiftUI

// MARK: - Sort order
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

// MARK: - Comments
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

    /// A comment the server asked "Are you sure?" about (rude wording): kept
    /// until the person sends it anyway or edits it.
    struct HeldComment {
        let postId: String
        let text: String
        /// Already uploaded, so sending anyway doesn't upload the photo twice.
        let imageUrl: String?
    }
    private(set) var held: HeldComment?
    /// Why the last comment was refused outright (threats, slurs).
    var refusal: String?
    private var refusedText: String?

    /// Muted comments the user chose to show anyway (this screen only).
    private(set) var revealed: Set<String> = []

    // MARK: - Collapsing
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

    // MARK: - Loading
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

    // MARK: - Photo attachment
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

    // MARK: - Sending
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
        return await send(postId: postId, text: trimmed, imageUrl: imageUrl, confirmed: false)
    }

    /// An HR offering one of their jobs on an "Open to work" post: a comment
    /// that is just the job's card.
    func offerJob(_ job: JobListing, postId: String) async -> Bool {
        isSending = true
        defer { isSending = false }
        do {
            let created = try await repository.addComment(postId: postId, content: "", jobId: job.id)
            comments.append(created)
            return true
        } catch {
            refusal = friendlyError(error)
            return false
        }
    }

    private func send(postId: String, text: String, imageUrl: String?, confirmed: Bool) async -> Bool {
        do {
            let created = try await repository.addComment(postId: postId, content: text, parentCommentId: replyingTo?.id,
                                                          imageUrl: imageUrl, confirmed: confirmed)
            comments.append(created)
            replyingTo = nil
            removePhoto()
            return true
        } catch {
            if ModerationMessage.isConfirmRequired(error) {
                held = HeldComment(postId: postId, text: text, imageUrl: imageUrl)
            } else if case APIError.serverError(422, _) = error {
                refusal = friendlyError(error)
                refusedText = text
            }
            return false
        }
    }

    /// "Post anyway" after "Are you sure?".
    func postHeld() async -> Bool {
        guard let h = held else { return false }
        held = nil
        isSending = true
        defer { isSending = false }
        return await send(postId: h.postId, text: h.text, imageUrl: h.imageUrl, confirmed: true)
    }

    /// "Edit": the text goes back to the field.
    func takeHeldText() -> String? {
        defer { held = nil }
        return held?.text
    }

    /// The refused text, for the field, once the person has read why.
    func takeRefusedText() -> String? {
        defer { refusedText = nil; refusal = nil }
        return refusedText
    }

    // MARK: - Delete, restore and edit
    /// Deletes one of your own comments for good. The backend soft-deletes its
    /// replies too, and the list drops the same rows at once. Returns how many
    /// comments were removed, so the caller can lower the post's count;
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
        if removed > 0 {
            // Same two-level cascade as the server: the comment, its replies,
            // and their replies. Kept with their places for an Undo.
            let gone = Set([commentId] + comments.filter { $0.parentCommentId == commentId }.map(\.id))
            let isGone: (CommentDTO) -> Bool = { gone.contains($0.id) || gone.contains($0.parentCommentId ?? "") }
            undoable[commentId] = comments.enumerated().filter { isGone($0.element) }.map { ($0.offset, $0.element) }
            comments.removeAll(where: isGone)
        }
        return removed
    }

    /// What each delete took, at its places in `comments`, until Undo or the toast goes.
    private var undoable: [String: [(index: Int, comment: CommentDTO)]] = [:]

    /// Undo of a delete, while its toast shows: the server brings the
    /// comment (and its replies) back, and they go back where they were.
    /// Returns how many came back, 0 if the server refused (too late).
    func restoreComment(postId: String, commentId: String) async -> Int {
        guard let token = authToken(), let saved = undoable.removeValue(forKey: commentId) else { return 0 }
        struct Response: Decodable { let restored: Int }
        do {
            let restored = try await NetworkClient.shared.fetch(
                Response.self,
                path: "/posts/\(postId)/comments/\(commentId)/restore",
                method: "POST",
                token: token
            ).restored
            for (index, comment) in saved.sorted(by: { $0.index < $1.index })
            where !comments.contains(where: { $0.id == comment.id }) {
                comments.insert(comment, at: min(index, comments.count))
            }
            return restored
        } catch {
            return 0
        }
    }

    /// Edits the content of one of your own comments and swaps the server's
    /// copy into the list in place, keeping what the edit response leaves out
    /// (who it replies to, mute state).
    func updateComment(postId: String, commentId: String, content: String) async -> Bool {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        // Editing changes the text only; a comment with a photo may lose it.
        let hasPhoto = comments.first { $0.id == commentId }?.imageUrl != nil
        guard !trimmed.isEmpty || hasPhoto else { return false }
        guard let updated = try? await repository.updateComment(postId: postId, commentId: commentId, content: trimmed) else {
            return false
        }
        if let i = comments.firstIndex(where: { $0.id == commentId }) {
            comments[i].content = updated.content
            comments[i].contentFormat = updated.contentFormat
            comments[i].editedAt = updated.editedAt
            // The old translation no longer matches; the server re-translates.
            comments[i].translatedText = nil
            comments[i].lang = updated.lang
        }
        return true
    }

    // MARK: - Likes
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
}

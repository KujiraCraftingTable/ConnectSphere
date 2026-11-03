import Foundation
import Observation

/// One post card's actions — like, save, hide, delete, restore, report — with
/// optimistic updates and rollback, and the app-wide notifications that keep
/// every other list showing this post in step. Held per card, seeded from the
/// post it renders.
@MainActor
@Observable
final class PostActionsViewModel {
    private(set) var isLiked: Bool
    private(set) var isSaved: Bool
    private(set) var likeCount: Int
    private(set) var commentCount: Int
    private(set) var shareCount: Int
    /// Someone else's post the user just hid (kept in the list so Undo can bring it back).
    private(set) var isHidden = false
    /// Outcome of a report, shown as an alert.
    var reportResultMessage: String?
    /// A delete / hide / restore failure, shown as an alert.
    var actionErrorMessage: String?

    private let repository = PostRepository()

    init(post: Post) {
        isLiked = post.isLiked
        isSaved = post.isSaved
        likeCount = post.likeCount
        commentCount = post.commentCount
        shareCount = post.shareCount
    }

    // MARK: Counts kept in step with the parent and the sheets

    /// A fresh `post` from the parent (e.g. a list patched after `.postUpdated`).
    func syncCommentCount(_ count: Int) { commentCount = count }
    func adjustCommentCount(by delta: Int) { commentCount = max(0, commentCount + delta) }
    func didShare() { shareCount += 1 }

    // MARK: Like / save (optimistic, rolled back on failure)

    func toggleLike(postId: String) async {
        let wasLiked = isLiked, wasCount = likeCount
        isLiked.toggle()
        likeCount += isLiked ? 1 : -1
        do {
            let result = try await repository.toggleLike(postId: postId)
            isLiked = result.liked
            likeCount = result.likeCount
        } catch {
            isLiked = wasLiked
            likeCount = wasCount
        }
    }

    /// Broadcasts the new saved state via `.postUpdated` — the Saved list drops
    /// an unsaved post right away.
    func toggleSave(post: Post) async {
        isSaved.toggle()
        do {
            if isSaved { try await repository.savePost(postId: post.id) }
            else       { try await repository.unsavePost(postId: post.id) }
            var updated = post
            updated.isSaved = isSaved
            NotificationCenter.default.post(name: .postUpdated, object: nil, userInfo: ["post": updated])
        } catch {
            isSaved.toggle()
        }
    }

    // MARK: Delete / restore

    /// Soft-deletes (kept 30 days in Recently Deleted) and tells every list to
    /// drop it. Returns true on success, so the caller can offer Undo.
    func delete(post: Post) async -> Bool {
        do {
            try await repository.deletePost(postId: post.id)
            NotificationCenter.default.post(name: .postDeleted, object: nil,
                                            userInfo: ["id": post.id, "authorId": post.author.id])
            return true
        } catch {
            actionErrorMessage = Bundle.app.loc("Couldn't delete post, please try again")
            return false
        }
    }

    /// Undo of a delete: lists re-insert the post via `.postRestored`.
    func restore(postId: String) async {
        do {
            let restored = try await repository.restorePost(postId: postId)
            NotificationCenter.default.post(name: .postRestored, object: nil, userInfo: ["post": restored])
        } catch {
            actionErrorMessage = Bundle.app.loc("Couldn't restore post, please try again")
        }
    }

    // MARK: Hide / unhide (someone else's post)

    /// Hidden at once, persisted server-side so a reload doesn't bring it back;
    /// shown again if the server refuses.
    func hide(postId: String) async {
        isHidden = true
        do {
            try await repository.hidePost(postId: postId)
        } catch {
            isHidden = false
            actionErrorMessage = Bundle.app.loc("Couldn't hide post, please try again")
        }
    }

    func unhide(postId: String) async {
        isHidden = false
        do {
            try await repository.unhidePost(postId: postId)
        } catch {
            actionErrorMessage = Bundle.app.loc("Couldn't unhide post, please try again")
        }
    }

    // MARK: Not interested / Show more like this

    /// Leaves the feed at once (like Hide) and tells ranking to show less
    /// like it, and less from its author.
    func notInterested(postId: String) async {
        isHidden = true
        do {
            try await repository.sendFeedback(postId: postId, kind: "less")
        } catch {
            isHidden = false
            actionErrorMessage = Bundle.app.loc("Couldn't save that, please try again")
        }
    }

    func showMoreLikeThis(postId: String) async {
        do {
            try await repository.sendFeedback(postId: postId, kind: "more")
        } catch {
            actionErrorMessage = Bundle.app.loc("Couldn't save that, please try again")
        }
    }

    /// Undo for either: the post comes back and the feedback is removed.
    func undoFeedback(postId: String) async {
        isHidden = false
        do {
            try await repository.removeFeedback(postId: postId)
        } catch {
            actionErrorMessage = Bundle.app.loc("Couldn't save that, please try again")
        }
    }

    // MARK: Report

    func report(postId: String, reason: ReportReason) async {
        do {
            try await repository.reportPost(postId: postId, reason: reason)
            reportResultMessage = Bundle.app.loc("Report submitted")
        } catch {
            reportResultMessage = Bundle.app.loc("Could not submit report. Please try again.")
        }
    }
}

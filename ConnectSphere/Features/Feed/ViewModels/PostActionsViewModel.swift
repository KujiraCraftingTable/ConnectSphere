import Foundation
import Observation

/// One post card's actions, like, save, hide, delete, restore, report, with
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
    /// Why this post is showing as the "Hidden, Undo" card, if it is. Kept in
    /// the shared registry (not in the card) so scrolling away doesn't lose it.
    var hiddenKind: HiddenKind? { HiddenPostsRegistry.shared.kind(for: postId) }
    var isHidden: Bool { hiddenKind != nil }
    /// A delete / hide / restore failure, shown as an alert.
    var actionErrorMessage: String?

    private let repository = PostRepository()
    private let userRepository = UserRepository()
    private let postId: String
    private let authorId: String
    let authorName: String

    init(post: Post) {
        postId = post.id
        authorId = post.author.id
        authorName = post.author.name
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

    /// Broadcasts the new saved state via `.postUpdated`. The Saved list drops
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
        HiddenPostsRegistry.shared.set(.hidden, for: postId)
        do {
            try await repository.hidePost(postId: postId)
        } catch {
            HiddenPostsRegistry.shared.remove(postId)
            actionErrorMessage = Bundle.app.loc("Couldn't hide post, please try again")
        }
    }

    func unhide(postId: String) async {
        HiddenPostsRegistry.shared.remove(postId)
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
        HiddenPostsRegistry.shared.set(.lessLikeThis, for: postId)
        do {
            try await repository.sendFeedback(postId: postId, kind: "less")
        } catch {
            HiddenPostsRegistry.shared.remove(postId)
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
        HiddenPostsRegistry.shared.remove(postId)
        do {
            try await repository.removeFeedback(postId: postId)
        } catch {
            actionErrorMessage = Bundle.app.loc("Couldn't save that, please try again")
        }
    }

    // MARK: Hide all from / block the author, and the one Undo for every kind

    /// "Hide all from this person", no block; their posts leave my lists.
    func hideAuthor() async {
        HiddenPostsRegistry.shared.set(.hiddenAuthor(name: authorName, authorId: authorId), for: postId)
        do {
            try await userRepository.hideAuthorPosts(userId: authorId)
        } catch {
            HiddenPostsRegistry.shared.remove(postId)
            actionErrorMessage = Bundle.app.loc("Couldn't save that, please try again")
        }
    }

    func blockAuthor() async {
        HiddenPostsRegistry.shared.set(.blocked(name: authorName, authorId: authorId), for: postId)
        do {
            try await userRepository.blockUser(userId: authorId)
        } catch {
            HiddenPostsRegistry.shared.remove(postId)
            actionErrorMessage = Bundle.app.loc("Couldn't save that, please try again")
        }
    }

    /// The Undo on the "Hidden" card: brings the post back and takes back
    /// whatever put it there.
    func undoHidden() async {
        guard let kind = hiddenKind else { return }
        HiddenPostsRegistry.shared.remove(postId)
        do {
            switch kind {
            case .hidden:               try await repository.unhidePost(postId: postId)
            case .lessLikeThis:         try await repository.removeFeedback(postId: postId)
            case .hiddenAuthor:         try await userRepository.unhideAuthorPosts(userId: authorId)
            case .blocked:              try await userRepository.unblockUser(userId: authorId)
            case .moderated:            break
            }
        } catch {
            HiddenPostsRegistry.shared.set(kind, for: postId)
            actionErrorMessage = Bundle.app.loc("Couldn't save that, please try again")
        }
    }

}

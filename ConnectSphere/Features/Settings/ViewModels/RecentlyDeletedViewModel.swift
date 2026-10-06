import Foundation
import Observation

/// The user's own soft-deleted posts and comments (kept 30 days server-side),
/// each restorable in place.
@MainActor
@Observable
final class RecentlyDeletedViewModel {
    private(set) var deletedPosts: [Post] = []
    private(set) var deletedComments: [DeletedComment] = []
    private(set) var isLoading = false
    private(set) var restoringPostIds: Set<String> = []
    private(set) var restoringCommentIds: Set<String> = []
    var errorMessage: String?

    private let repository = PostRepository()

    var isEmpty: Bool { deletedPosts.isEmpty && deletedComments.isEmpty }

    func load() async {
        isLoading = true
        async let postsTask    = try? repository.fetchDeletedPosts()
        async let commentsTask = try? repository.fetchDeletedComments()
        deletedPosts    = await postsTask ?? []
        deletedComments = await commentsTask ?? []
        isLoading = false
    }

    /// Restores a post and removes it from this list; also notifies
    /// Feed/Profile (via `.postRestored`) so it reappears there without a
    /// manual refresh — the same convention the Undo toast uses.
    func restorePost(_ post: Post) async {
        restoringPostIds.insert(post.id)
        defer { restoringPostIds.remove(post.id) }
        do {
            let restored = try await repository.restorePost(postId: post.id)
            deletedPosts.removeAll { $0.id == post.id }
            NotificationCenter.default.post(name: .postRestored, object: nil, userInfo: ["post": restored])
        } catch {
            errorMessage = Bundle.app.loc("Could not restore this post. Please try again.")
        }
    }

    func restoreComment(_ comment: DeletedComment) async {
        restoringCommentIds.insert(comment.id)
        defer { restoringCommentIds.remove(comment.id) }
        do {
            try await repository.restoreComment(postId: comment.postId, commentId: comment.id)
            deletedComments.removeAll { $0.id == comment.id }
        } catch {
            errorMessage = Bundle.app.loc("Could not restore this comment. Please try again.")
        }
    }
}

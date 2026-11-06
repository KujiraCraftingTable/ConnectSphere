import Foundation
import Observation

/// One post, opened full screen with its comments. The comment list has its
/// own `CommentViewModel`, shared with the pinned composer.
@MainActor
@Observable
final class PostDetailViewModel {
    let postId: String
    var post: Post?
    /// The post is gone or not visible to this user.
    private(set) var loadFailed = false
    /// Backs the top bar's ⋯ menu (edit, delete, hide, report); the card
    /// below keeps its own for likes, comments and shares.
    private(set) var actions: PostActionsViewModel?

    private let repository = PostRepository()

    init(postId: String) {
        self.postId = postId
    }

    /// Fetches once, `.task` re-runs when the view reappears. Returns true
    /// when the post is available (so comments can load).
    func loadPost() async -> Bool {
        if post != nil { return true }
        guard !loadFailed else { return false }
        do {
            let loaded = try await repository.fetchPost(id: postId)
            post = loaded
            actions = PostActionsViewModel(post: loaded)
            return true
        } catch {
            loadFailed = true
            return false
        }
    }

    /// Optimistically adjusts the displayed comment count and broadcasts it via
    /// `.postUpdated`, so Feed/Profile lists already in memory follow. The
    /// server updated its own count already and stays the source of truth.
    func adjustCommentCount(by delta: Int) {
        guard var p = post else { return }
        p.commentCount = max(0, p.commentCount + delta)
        post = p
        NotificationCenter.default.post(name: .postUpdated, object: nil, userInfo: ["post": p])
    }
}

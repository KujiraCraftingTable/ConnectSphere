import Foundation
import Observation

/// The user's own soft-deleted posts (kept 30 days server-side), each
/// restorable in place. Deleted comments are gone for good.
@MainActor
@Observable
final class RecentlyDeletedViewModel {
    private(set) var deletedPosts: [Post] = []
    private(set) var isLoading = false
    private(set) var restoringPostIds: Set<String> = []
    var errorMessage: String?

    private let repository = PostRepository()

    var isEmpty: Bool { deletedPosts.isEmpty }

    func load() async {
        isLoading = true
        deletedPosts = (try? await repository.fetchDeletedPosts()) ?? []
        isLoading = false
    }

    /// Restores a post and removes it from this list; also notifies
    /// Feed/Profile (via `.postRestored`) so it reappears there without a
    /// manual refresh, the same convention the Undo toast uses.
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

}

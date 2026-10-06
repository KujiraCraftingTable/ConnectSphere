import Foundation
import Observation

/// The user's saved (bookmarked) posts.
@MainActor
@Observable
final class SavedPostsViewModel {
    private(set) var posts: [Post] = []
    private(set) var isLoading = false
    var errorMessage: String?

    private let repository = PostRepository()

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            posts = try await repository.fetchSavedPosts()
        } catch {
            errorMessage = friendlyError(error)
        }
    }

    /// A post changed somewhere in the app. Unsaved → drop it right away;
    /// still saved → patch it in place. (A generic feed only ever patches;
    /// the Saved list must also remove — the same asymmetry Recently Deleted
    /// handles for delete/restore.)
    func postUpdated(_ updated: Post) {
        if updated.isSaved {
            if let i = posts.firstIndex(where: { $0.id == updated.id }) { posts[i] = updated }
        } else {
            posts.removeAll { $0.id == updated.id }
        }
    }

    func postDeleted(id: String) {
        posts.removeAll { $0.id == id }
    }
}

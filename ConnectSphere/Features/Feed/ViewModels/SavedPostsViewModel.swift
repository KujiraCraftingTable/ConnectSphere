import Foundation
import Observation

/// The user's saved (bookmarked) posts, and separately their saved
/// Marketplace items — the two tabs of Saved.
@MainActor
@Observable
final class SavedPostsViewModel {
    enum Tab: Hashable { case posts, marketplace }

    var tab: Tab = .posts
    private(set) var posts: [Post] = []
    private(set) var listings: [Post] = []
    private(set) var isLoading = false
    var errorMessage: String?
    /// Tabs fetched at least once — each loads when it's first opened.
    private var loaded: Set<Tab> = []

    private let repository = PostRepository()

    var isEmpty: Bool { tab == .posts ? posts.isEmpty : listings.isEmpty }

    /// Loads the open tab; `force` refetches (pull to refresh).
    func load(force: Bool = false) async {
        let tab = tab
        guard force || !loaded.contains(tab) else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let fetched = try await repository.fetchSavedPosts(listings: tab == .marketplace)
            if tab == .posts { posts = fetched } else { listings = fetched }
            loaded.insert(tab)
        } catch {
            errorMessage = friendlyError(error)
        }
    }

    /// A post changed somewhere in the app. Unsaved → drop it right away;
    /// still saved → patch it in place, or add a newly saved item to the top
    /// of its tab. (A generic feed only ever patches; the Saved list must also
    /// remove — the same asymmetry Recently Deleted handles for delete/restore.)
    func postUpdated(_ updated: Post) {
        if updated.postType == .listing { apply(updated, to: &listings) } else { apply(updated, to: &posts) }
    }

    private func apply(_ updated: Post, to list: inout [Post]) {
        if !updated.isSaved {
            list.removeAll { $0.id == updated.id }
        } else if let i = list.firstIndex(where: { $0.id == updated.id }) {
            list[i] = updated
        } else {
            list.insert(updated, at: 0)
        }
    }

    func postDeleted(id: String) {
        posts.removeAll { $0.id == id }
        listings.removeAll { $0.id == id }
    }
}

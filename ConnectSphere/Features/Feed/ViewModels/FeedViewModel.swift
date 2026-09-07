import Foundation
import Observation

/// The feed's data source: personalized recommendations (default) or connections-only posts.
enum FeedScope: String {
    case forYou
    case connections
}

@MainActor
@Observable
class FeedViewModel {
    var friendPosts: [Post] = []
    var colleaguePosts: [Post] = []
    var isLoading = false
    var isLoadingMore = false
    var error: String?
    /// The current feed source — change this value then call loadPosts(for:) to switch data sources
    var feedScope: FeedScope = .forYou

    private let repository = PostRepository()
    private let pageSize = 20
    private var loadedModes: Set<AppMode> = []
    private var hasMore: [AppMode: Bool] = [:]
    /// Next-page cursor for the .forYou scope (personalized feed); nil = start from the beginning
    private var nextCursor: [AppMode: String?] = [:]
    /// Next-page offset for the .connections scope (offset-style pagination, no cursor)
    private var connectionsOffset: [AppMode: Int] = [:]
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

    init() {
        observers.append(NotificationCenter.default.addObserver(
            forName: .postDeleted, object: nil, queue: .main
        ) { [weak self] note in
            guard let id = note.userInfo?["id"] as? String else { return }
            self?.removePost(id: id)
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .postUpdated, object: nil, queue: .main
        ) { [weak self] note in
            guard let post = note.userInfo?["post"] as? Post else { return }
            self?.updatePost(post)
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .postRestored, object: nil, queue: .main
        ) { [weak self] note in
            guard let post = note.userInfo?["post"] as? Post else { return }
            self?.restorePost(post)
        })
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    func posts(for mode: AppMode) -> [Post] {
        mode == .hobby ? friendPosts : colleaguePosts
    }

    func loadPostsIfNeeded(for mode: AppMode) async {
        guard !loadedModes.contains(mode) else { return }
        await loadPosts(for: mode)
    }

    /// Loads the first page (resets pagination) — the data source depends on the current feedScope.
    func loadPosts(for mode: AppMode) async {
        isLoading = true
        error = nil
        do {
            switch feedScope {
            case .forYou:
                let page = try await repository.fetchRecommendedFeed(
                    mode: mode, cursor: nil, limit: pageSize
                )
                nextCursor[mode] = page.nextCursor
                hasMore[mode]    = page.nextCursor != nil
                setPosts(page.posts, for: mode)
            case .connections:
                let fetched = try await repository.fetchPosts(
                    mode: mode, connectionsOnly: true, limit: pageSize, offset: 0
                )
                connectionsOffset[mode] = fetched.count
                hasMore[mode] = fetched.count == pageSize
                setPosts(fetched, for: mode)
            }
            loadedModes.insert(mode)
        } catch {
            self.error = friendlyError(error)
        }
        isLoading = false
    }

    /// Loads the next page when the user scrolls to the end of the list
    func loadMorePosts(for mode: AppMode) async {
        guard !isLoadingMore, hasMore[mode] == true else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        let current = posts(for: mode)
        let existingIds = Set(current.map(\.id))
        do {
            switch feedScope {
            case .forYou:
                let page = try await repository.fetchRecommendedFeed(
                    mode: mode, cursor: nextCursor[mode] ?? nil, limit: pageSize
                )
                nextCursor[mode] = page.nextCursor
                hasMore[mode]    = page.nextCursor != nil
                // Avoid duplicates when a new post slips in between two fetches
                appendPosts(page.posts.filter { !existingIds.contains($0.id) }, for: mode)
            case .connections:
                let offset = connectionsOffset[mode] ?? 0
                let fetched = try await repository.fetchPosts(
                    mode: mode, connectionsOnly: true, limit: pageSize, offset: offset
                )
                connectionsOffset[mode] = offset + fetched.count
                hasMore[mode] = fetched.count == pageSize
                appendPosts(fetched.filter { !existingIds.contains($0.id) }, for: mode)
            }
        } catch {
            // Scrolling further will retry — don't show an error that blocks the feed
        }
    }

    func removePost(id: String) {
        friendPosts.removeAll   { $0.id == id }
        colleaguePosts.removeAll { $0.id == id }
    }

    /// Insert a freshly-created post at the top of its mode's list right
    /// after posting, so the user sees confirmation immediately instead of
    /// waiting on (or having to notice) a background reload — de-dupes
    /// defensively in case a reload already picked it up first.
    func prependPost(_ post: Post, for mode: AppMode) {
        if mode == .hobby {
            friendPosts.removeAll { $0.id == post.id }
            friendPosts.insert(post, at: 0)
        } else {
            colleaguePosts.removeAll { $0.id == post.id }
            colleaguePosts.insert(post, at: 0)
        }
    }

    func updatePost(_ updated: Post) {
        if let i = friendPosts.firstIndex(where: { $0.id == updated.id }) {
            friendPosts[i] = updated
        }
        if let i = colleaguePosts.firstIndex(where: { $0.id == updated.id }) {
            colleaguePosts[i] = updated
        }
    }

    /// Re-inserts a post restored via the Undo toast or the Recently Deleted
    /// screen — unlike `updatePost`, it inserts at the top when the post
    /// isn't currently in the list (it was just removed by `.postDeleted`),
    /// and patches it in place if a reload already picked it back up first.
    func restorePost(_ post: Post) {
        if post.mode == .hobby {
            if let i = friendPosts.firstIndex(where: { $0.id == post.id }) {
                friendPosts[i] = post
            } else {
                friendPosts.insert(post, at: 0)
            }
        } else {
            if let i = colleaguePosts.firstIndex(where: { $0.id == post.id }) {
                colleaguePosts[i] = post
            } else {
                colleaguePosts.insert(post, at: 0)
            }
        }
    }

    // MARK: - Private helpers

    private func setPosts(_ newPosts: [Post], for mode: AppMode) {
        if mode == .hobby { friendPosts = newPosts } else { colleaguePosts = newPosts }
    }

    private func appendPosts(_ newPosts: [Post], for mode: AppMode) {
        if mode == .hobby { friendPosts += newPosts } else { colleaguePosts += newPosts }
    }
}

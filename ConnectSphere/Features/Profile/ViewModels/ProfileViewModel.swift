import Foundation
import Observation

@MainActor
@Observable
class ProfileViewModel {
    var user: UserProfile?
    var posts: [Post] = []
    var isLoading = false
    var isLoadingMore = false
    var hasMore = true
    var error: String?

    private let repository = ProfileRepository()
    private let pageSize = 20
    private var offset = 0
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
        // A new post was created — most likely from Home Feed's composer,
        // since this same screen's own composer already triggers a full
        // `load()` refetch on success. Without this, `user.postCount` (the
        // header stats card) undercounts until the next full reload if the
        // user created a post elsewhere while this view model stayed alive
        // in memory (switching tabs doesn't tear it down).
        observers.append(NotificationCenter.default.addObserver(
            forName: .postCreated, object: nil, queue: .main
        ) { [weak self] note in
            guard let post = note.userInfo?["post"] as? Post else { return }
            self?.addNewPost(post)
        })
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    func removePost(id: String) {
        let wasPresent = posts.contains { $0.id == id }
        posts.removeAll { $0.id == id }
        // Read postCount into a local BEFORE the `user?.postCount = ...` assignment:
        // reading and writing `user?.postCount` in the same optional-chained
        // assignment statement triggers a Swift exclusivity-access crash
        // (overlapping getter/setter access on the @Observable `user` property).
        if wasPresent, let currentCount = user?.postCount {
            user?.postCount = max(currentCount - 1, 0)
        }
    }

    func updatePost(_ updated: Post) {
        if let i = posts.firstIndex(where: { $0.id == updated.id }) {
            posts[i] = updated
        }
    }

    /// Re-inserts a post restored via the Undo toast or the Recently Deleted
    /// screen — inserts at the top if it isn't currently in the list (it was
    /// just removed by `.postDeleted`), patches in place otherwise. Symmetric
    /// with `removePost`'s decrement: only bump `postCount` back up when the
    /// post genuinely wasn't already present (a patch-in-place means some
    /// other reload already restored it, whose fresh `postCount` from the
    /// server we shouldn't then double-increment).
    func restorePost(_ post: Post) {
        let wasAbsent = !posts.contains { $0.id == post.id }
        if let i = posts.firstIndex(where: { $0.id == post.id }) {
            posts[i] = post
        } else {
            posts.insert(post, at: 0)
        }
        if wasAbsent, let currentCount = user?.postCount {
            user?.postCount = currentCount + 1
        }
    }

    /// A new post was created somewhere in the app (usually Home Feed's
    /// composer). Only applies when it's genuinely the profile being viewed
    /// here — this view model is only ever used for the current user's own
    /// profile, but the author-id check costs nothing and matches the same
    /// defensive pattern `AppState`'s observers use.
    func addNewPost(_ post: Post) {
        guard post.author.id == user?.id, !posts.contains(where: { $0.id == post.id }) else { return }
        posts.insert(post, at: 0)
        if let currentCount = user?.postCount {
            user?.postCount = currentCount + 1
        }
    }

    func load(userId: String, mode: String? = nil) async {
        isLoading = true
        error = nil
        offset = 0
        do {
            async let userResult  = repository.fetchUser(userId: userId, mode: mode)
            async let postsResult = repository.fetchPosts(authorId: userId, mode: mode, limit: pageSize, offset: 0)
            let (u, p) = try await (userResult, postsResult)
            user  = u
            posts = p
            hasMore = p.count == pageSize
            offset = p.count
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    func loadMorePosts(userId: String, mode: String?) async {
        guard !isLoadingMore, hasMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        let existingIds = Set(posts.map(\.id))
        do {
            let fetched = try await repository.fetchPosts(authorId: userId, mode: mode, limit: pageSize, offset: offset)
            hasMore = fetched.count == pageSize
            offset += fetched.count
            posts += fetched.filter { !existingIds.contains($0.id) }
        } catch {
            // Scrolling further retries — don't block the already-loaded list.
        }
    }
}

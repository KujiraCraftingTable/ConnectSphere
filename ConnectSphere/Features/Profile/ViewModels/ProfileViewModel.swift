import Foundation
import Observation

@MainActor
@Observable
class ProfileViewModel {
    var user: UserProfile?

    /// Follow or unfollow tapped on this profile: move the shown count at once
    /// instead of waiting for the next reload.
    func adjustFollowerCount(by delta: Int) {
        guard delta != 0, var shown = user else { return }
        shown.followerCount = max(0, shown.followerCount + delta)
        user = shown
    }
    var posts: [Post] = []
    var isLoading = false
    var isLoadingMore = false
    var hasMore = true
    var error: String?

    // Viewing someone else's profile:
    /// Whether the current user has blocked this profile's user.
    private(set) var isBlocked = false
    /// Block/unblock failure, shown as an alert (load errors use `error`).
    var actionError: String?
    private(set) var isOpeningChat = false

    /// Unlocks your own profile for `mode`. Optimistic: the badge goes at once and
    /// comes back if saving fails.
    func unlock(mode: AppMode, appState: AppState) async {
        user?.isLocked = false
        appState.currentUser?.isLocked = false
        do {
            try await repository.setLocked(false, mode: mode)
        } catch {
            user?.isLocked = true
            appState.currentUser?.isLocked = true
            actionError = Bundle.app.loc("Couldn't update this setting, please try again")
        }
    }

    private let repository = ProfileRepository()
    private let userRepository = UserRepository()
    private let messageRepository = MessageRepository()
    private let pageSize = 20
    /// The mode `posts`/`user` were last loaded for. Guards addNewPost/
    /// restorePost from splicing in a post from the other mode (mirrors
    /// FeedViewModel.restorePost's post.mode branch).
    private var loadedMode: String?
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
        // A new post was created. Most likely from Home Feed's composer,
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
    /// screen, inserts at the top if it isn't currently in the list (it was
    /// just removed by `.postDeleted`), patches in place otherwise. Symmetric
    /// with `removePost`'s decrement: only bump `postCount` back up when the
    /// post genuinely wasn't already present (a patch-in-place means some
    /// other reload already restored it, whose fresh `postCount` from the
    /// server we shouldn't then double-increment).
    func restorePost(_ post: Post) {
        guard post.mode.rawValue == loadedMode else { return }
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
    /// here, this view model is only ever used for the current user's own
    /// profile, but the author-id check costs nothing and matches the same
    /// defensive pattern `AppState`'s observers use.
    func addNewPost(_ post: Post) {
        guard post.author.id == user?.id, post.mode.rawValue == loadedMode,
              !posts.contains(where: { $0.id == post.id }) else { return }
        posts.insert(post, at: 0)
        if let currentCount = user?.postCount {
            user?.postCount = currentCount + 1
        }
    }

    func load(userId: String, mode: String? = nil) async {
        isLoading = true
        error = nil
        offset = 0
        loadedMode = mode
        do {
            async let userResult  = repository.fetchUser(userId: userId, mode: mode)
            async let postsResult = repository.fetchPosts(authorId: userId, mode: mode, limit: pageSize, offset: 0)
            let (u, p) = try await (userResult, postsResult)
            user  = u
            posts = p
            hasMore = p.count == pageSize
            offset = p.count
        } catch {
            self.error = friendlyError(error)
        }
        isLoading = false
    }

    /// Pull-to-refresh: like `load` but the profile and posts stay on screen
    /// while it runs (no spinner swap), and a failed pull keeps them. With
    /// nothing on screen yet (the first load failed) a failed pull updates the
    /// error instead, so the screen never sits on a skeleton.
    func refresh(userId: String, mode: String? = nil) async {
        do {
            async let userResult  = repository.fetchUser(userId: userId, mode: mode)
            async let postsResult = repository.fetchPosts(authorId: userId, mode: mode, limit: pageSize, offset: 0)
            let (u, p) = try await (userResult, postsResult)
            user = u
            posts = p
            loadedMode = mode
            hasMore = p.count == pageSize
            offset = p.count
            error = nil
        } catch {
            if user == nil { self.error = friendlyError(error) }
        }
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
            // Scrolling further retries, don't block the already-loaded list.
        }
    }

    // MARK: Another user's profile

    func loadBlockStatus(userId: String) async {
        isBlocked = (try? await userRepository.fetchBlockStatus(userId: userId)) ?? false
    }

    /// Blocks or unblocks. Any open ChatView with this user refreshes live via
    /// `.userBlockStatusChanged`. On failure the state stays and the error shows.
    func toggleBlock(userId: String) async {
        do {
            if isBlocked {
                try await userRepository.unblockUser(userId: userId)
            } else {
                try await userRepository.blockUser(userId: userId)
            }
            isBlocked.toggle()
            NotificationCenter.default.post(name: .userBlockStatusChanged, object: nil, userInfo: ["userId": userId])
        } catch {
            actionError = friendlyError(error)
        }
    }

    /// The conversation to open, or nil (fails silently. The user can tap again).
    func openConversation(with userId: String, mode: AppMode, token: String?) async -> String? {
        guard let token else { return nil }
        isOpeningChat = true
        defer { isOpeningChat = false }
        return try? await messageRepository.openConversation(otherUserId: userId, mode: mode.rawValue, token: token)
    }
}

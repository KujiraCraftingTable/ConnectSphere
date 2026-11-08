import Foundation
import Observation

/// The feed's data source: personalized recommendations (default), friends' posts, or posts from people you follow.
enum FeedScope: String {
    case forYou
    case connections
    /// People you follow who aren't your friends.
    case following

    /// The posts-list filter for the offset-paged scopes.
    var listFilter: String? {
        switch self {
        case .forYou: return nil
        case .connections: return "connections"
        case .following: return "following"
        }
    }
}

@MainActor
@Observable
class FeedViewModel {
    var friendPosts: [Post] = []
    var colleaguePosts: [Post] = []
    var isLoading = false
    var isLoadingMore = false
    var error: String?
    /// The current feed source. Change this value then call loadPosts(for:) to switch data sources
    var feedScope: FeedScope = .forYou

    private let repository = PostRepository()
    private let pageSize = 20
    private var loadedModes: Set<AppMode> = []
    private var hasMore: [AppMode: Bool] = [:]
    /// Next-page cursor for the .forYou scope (personalized feed); nil = start from the beginning
    private var nextCursor: [AppMode: String?] = [:]
    /// Next-page offset for the .connections / .following scopes (offset-style pagination, no cursor)
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
        // Muting or unmuting changes what the server returns: the next time
        // the feed shows (it's on another tab while Settings is open) it
        // refetches instead of keeping posts that should now be hidden.
        observers.append(NotificationCenter.default.addObserver(
            forName: .mutedWordsChanged, object: nil, queue: .main
        ) { [weak self] _ in
            self?.loadedModes.removeAll()
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

    /// Bumped by every `loadPosts`: a response from an older load (a quick
    /// mode switch, scope change, Home re-tap or refresh) is dropped instead
    /// of overwriting the newer one.
    private var loadGeneration = 0
    private var loadTask: Task<Void, Never>?

    /// Loads the first page (resets pagination). The data source depends on the current feedScope.
    /// Cancels a load still in flight.
    func loadPosts(for mode: AppMode) async {
        // A refresh drops the "Hidden, Undo" cards: the server no longer sends those posts.
        HiddenPostsRegistry.shared.clear()
        loadTask?.cancel()
        loadGeneration += 1
        let generation = loadGeneration
        let scope = feedScope
        isLoading = true
        error = nil
        let task = Task { await loadFirstPage(for: mode, scope: scope, generation: generation) }
        loadTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func isCurrent(_ generation: Int) -> Bool {
        generation == loadGeneration && !Task.isCancelled
    }

    private func loadFirstPage(for mode: AppMode, scope: FeedScope, generation: Int) async {
        defer { if generation == loadGeneration { isLoading = false } }
        // The first time a mode's For you shows, the last cached page appears
        // at once instead of a spinner; the fresh page replaces it.
        if scope == .forYou, posts(for: mode).isEmpty,
           let cached = repository.cachedRecommendedFeed(mode: mode) {
            setPosts(cached, for: mode)
        }
        do {
            switch scope {
            case .forYou:
                let page = try await repository.fetchRecommendedFeed(
                    mode: mode, cursor: nil, limit: pageSize
                )
                guard isCurrent(generation) else { return }
                nextCursor[mode] = page.nextCursor
                hasMore[mode]    = page.nextCursor != nil
                setPosts(page.posts, for: mode)
            case .connections, .following:
                let fetched = try await repository.fetchPosts(
                    mode: mode, filter: scope.listFilter, limit: pageSize, offset: 0
                )
                guard isCurrent(generation) else { return }
                connectionsOffset[mode] = fetched.count
                hasMore[mode] = fetched.count == pageSize
                setPosts(fetched, for: mode)
            }
            loadedModes.insert(mode)
        } catch {
            guard isCurrent(generation) else { return }
            self.error = friendlyError(error)
        }
    }

    /// Loads the next page when the user scrolls to the end of the list
    func loadMorePosts(for mode: AppMode) async {
        guard !isLoadingMore, hasMore[mode] == true else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        let generation = loadGeneration
        let current = posts(for: mode)
        let existingIds = Set(current.map(\.id))
        do {
            switch feedScope {
            case .forYou:
                let page = try await repository.fetchRecommendedFeed(
                    mode: mode, cursor: nextCursor[mode] ?? nil, limit: pageSize
                )
                // A reload started meanwhile: this page belongs to the old list.
                guard generation == loadGeneration else { return }
                nextCursor[mode] = page.nextCursor
                hasMore[mode]    = page.nextCursor != nil
                // Avoid duplicates when a new post slips in between two fetches
                appendPosts(page.posts.filter { !existingIds.contains($0.id) }, for: mode)
            case .connections, .following:
                let offset = connectionsOffset[mode] ?? 0
                let fetched = try await repository.fetchPosts(
                    mode: mode, filter: feedScope.listFilter, limit: pageSize, offset: offset
                )
                guard generation == loadGeneration else { return }
                connectionsOffset[mode] = offset + fetched.count
                hasMore[mode] = fetched.count == pageSize
                appendPosts(fetched.filter { !existingIds.contains($0.id) }, for: mode)
            }
        } catch {
            // Scrolling further will retry, don't show an error that blocks the feed
        }
    }

    func removePost(id: String) {
        // Keep the connections-scope page offset in step with a local removal,
        // otherwise the next fetched page skips a row.
        if friendPosts.contains(where: { $0.id == id }), let o = connectionsOffset[.hobby], o > 0 {
            connectionsOffset[.hobby] = o - 1
        }
        if colleaguePosts.contains(where: { $0.id == id }), let o = connectionsOffset[.work], o > 0 {
            connectionsOffset[.work] = o - 1
        }
        friendPosts.removeAll   { $0.id == id }
        colleaguePosts.removeAll { $0.id == id }
    }

    /// Insert a freshly-created post at the top of its mode's list right
    /// after posting, so the user sees confirmation immediately instead of
    /// waiting on (or having to notice) a background reload, de-dupes
    /// defensively in case a reload already picked it up first.
    func prependPost(_ post: Post, for mode: AppMode) {
        let list = mode == .hobby ? friendPosts : colleaguePosts
        let wasAlreadyPresent = list.contains { $0.id == post.id }
        if mode == .hobby {
            friendPosts.removeAll { $0.id == post.id }
            friendPosts.insert(post, at: 0)
        } else {
            colleaguePosts.removeAll { $0.id == post.id }
            colleaguePosts.insert(post, at: 0)
        }
        // A genuinely new row shifts the connections window by one.
        if !wasAlreadyPresent, let o = connectionsOffset[mode] { connectionsOffset[mode] = o + 1 }
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
    /// screen, unlike `updatePost`, it inserts at the top when the post
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

    // MARK: - Create-post bar avatar & chat badge

    /// This mode's persona for the create-post bar's avatar. `AppState.currentUser`
    /// is one unscoped cache that isn't refetched on mode switch, so it can't
    /// show a per-mode avatar (the same fix as StoriesViewModel).
    private(set) var myProfile: UserProfile?
    private let profileRepository = ProfileRepository()
    private let messageRepository = MessageRepository()

    func loadMyProfile(userId: String?, mode: AppMode) async {
        guard let userId else { return }
        myProfile = try? await profileRepository.fetchUser(userId: userId, mode: mode.rawValue)
    }

    /// Unread chats in the current mode → the Messages badge (kept on AppState,
    /// which the tab bar also reads).
    func refreshChatUnread(appState: AppState) async {
        guard let token = appState.authToken else { return }
        appState.chatUnreadCount = (try? await messageRepository.fetchUnreadCount(
            mode: appState.currentMode.rawValue, token: token)) ?? 0
    }

    /// Connects the socket and keeps the badge live on every new message.
    func startChatBadge(appState: AppState) {
        guard let token = appState.authToken else { return }
        WebSocketClient.shared.connect(token: token)
        WebSocketClient.shared.on("new_message", tag: "feedBadge") { [weak self, appState] _ in
            Task { @MainActor in await self?.refreshChatUnread(appState: appState) }
        }
        // Theme/nickname/accept notes count as unread too.
        WebSocketClient.shared.on("conversation_event", tag: "feedBadge") { [weak self, appState] _ in
            Task { @MainActor in await self?.refreshChatUnread(appState: appState) }
        }
        Task { await refreshChatUnread(appState: appState) }
    }

    func stopChatBadge() {
        WebSocketClient.shared.off("new_message", tag: "feedBadge")
        WebSocketClient.shared.off("conversation_event", tag: "feedBadge")
    }
}

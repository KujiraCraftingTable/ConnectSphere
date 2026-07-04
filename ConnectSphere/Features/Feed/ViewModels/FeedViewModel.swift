import Foundation
import Observation

/// Phạm vi feed: tất cả bài public, hoặc chỉ bài của người đã kết nối
enum FeedScope: String, CaseIterable {
    case all
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

    /// Đổi scope → reload lại feed của mode hiện tại từ đầu
    var feedScope: FeedScope = .all

    private let repository = PostRepository()
    private let pageSize = 20
    private var loadedModes: Set<AppMode> = []
    private var hasMore: [AppMode: Bool] = [:]
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
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    func posts(for mode: AppMode) -> [Post] {
        mode == .friend ? friendPosts : colleaguePosts
    }

    func loadPostsIfNeeded(for mode: AppMode) async {
        guard !loadedModes.contains(mode) else { return }
        await loadPosts(for: mode)
    }

    /// Tải trang đầu (reset phân trang)
    func loadPosts(for mode: AppMode) async {
        isLoading = true
        error = nil
        do {
            let posts = try await repository.fetchPosts(
                mode: mode,
                connectionsOnly: feedScope == .connections,
                limit: pageSize,
                offset: 0
            )
            if mode == .friend { friendPosts = posts } else { colleaguePosts = posts }
            hasMore[mode] = posts.count == pageSize
            loadedModes.insert(mode)
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    /// Tải trang tiếp theo khi cuộn tới cuối danh sách
    func loadMorePosts(for mode: AppMode) async {
        guard !isLoadingMore, hasMore[mode] == true else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let current = posts(for: mode)
            let more = try await repository.fetchPosts(
                mode: mode,
                connectionsOnly: feedScope == .connections,
                limit: pageSize,
                offset: current.count
            )
            // Tránh trùng khi có bài mới chen vào giữa 2 lần fetch
            let existingIds = Set(current.map(\.id))
            let fresh = more.filter { !existingIds.contains($0.id) }
            if mode == .friend { friendPosts += fresh } else { colleaguePosts += fresh }
            hasMore[mode] = more.count == pageSize
        } catch {
            // Cuộn tiếp sẽ retry — không hiện lỗi chặn feed
        }
    }

    /// Đổi phạm vi feed và reload
    func switchScope(_ scope: FeedScope, mode: AppMode) async {
        guard scope != feedScope else { return }
        feedScope = scope
        loadedModes.removeAll()
        await loadPosts(for: mode)
    }

    func removePost(id: String) {
        friendPosts.removeAll   { $0.id == id }
        colleaguePosts.removeAll { $0.id == id }
    }

    func updatePost(_ updated: Post) {
        if let i = friendPosts.firstIndex(where: { $0.id == updated.id }) {
            friendPosts[i] = updated
        }
        if let i = colleaguePosts.firstIndex(where: { $0.id == updated.id }) {
            colleaguePosts[i] = updated
        }
    }
}

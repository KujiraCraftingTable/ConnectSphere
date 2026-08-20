import Foundation
import Observation

/// Nguồn dữ liệu của feed: gợi ý cá nhân hoá (mặc định) hoặc chỉ bài của connections.
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
    /// Nguồn feed hiện tại — đổi giá trị này rồi gọi loadPosts(for:) để chuyển nguồn dữ liệu
    var feedScope: FeedScope = .forYou

    private let repository = PostRepository()
    private let pageSize = 20
    private var loadedModes: Set<AppMode> = []
    private var hasMore: [AppMode: Bool] = [:]
    /// Cursor trang kế cho scope .forYou (personalized feed); nil = còn từ đầu
    private var nextCursor: [AppMode: String?] = [:]
    /// Offset trang kế cho scope .connections (phân trang kiểu offset, không có cursor)
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

    /// Tải trang đầu (reset phân trang) — nguồn dữ liệu phụ thuộc feedScope hiện tại.
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
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    /// Tải trang tiếp theo khi cuộn tới cuối danh sách
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
                // Tránh trùng khi có bài mới chen vào giữa 2 lần fetch
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
            // Cuộn tiếp sẽ retry — không hiện lỗi chặn feed
        }
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

    // MARK: - Private helpers

    private func setPosts(_ newPosts: [Post], for mode: AppMode) {
        if mode == .hobby { friendPosts = newPosts } else { colleaguePosts = newPosts }
    }

    private func appendPosts(_ newPosts: [Post], for mode: AppMode) {
        if mode == .hobby { friendPosts += newPosts } else { colleaguePosts += newPosts }
    }
}

import Foundation
import Observation

/// Posts with one hashtag, in one mode (like every other post list), paged.
@MainActor
@Observable
final class TagFeedViewModel {
    static let pageSize = 20

    let tag: String
    let mode: AppMode
    private(set) var posts: [Post] = []
    private(set) var isLoading = false
    private(set) var isLoadingMore = false
    private(set) var loadError: String?
    private var offset = 0
    private var hasMore = true

    private let repository = PostRepository()

    init(tag: String, mode: AppMode) {
        self.tag = tag
        self.mode = mode
    }

    /// First page; resets pagination.
    func load() async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        offset = 0
        hasMore = true
        do {
            let fetched = try await repository.fetchPostsByTag(tag, mode: mode, limit: Self.pageSize, offset: 0)
            posts = fetched
            offset = fetched.count
            hasMore = fetched.count == Self.pageSize
        } catch {
            loadError = friendlyError(error)
        }
    }

    /// Next page, when the list scrolls to its end. Duplicates (a post that
    /// shifted pages) are skipped.
    func loadMore() async {
        guard !isLoadingMore, hasMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        let fetched = (try? await repository.fetchPostsByTag(tag, mode: mode, limit: Self.pageSize, offset: offset)) ?? []
        let existingIds = Set(posts.map(\.id))
        posts += fetched.filter { !existingIds.contains($0.id) }
        offset += fetched.count
        hasMore = fetched.count == Self.pageSize
    }

    func remove(id: String) { posts.removeAll { $0.id == id } }

    func update(_ post: Post) {
        if let i = posts.firstIndex(where: { $0.id == post.id }) { posts[i] = post }
    }
}

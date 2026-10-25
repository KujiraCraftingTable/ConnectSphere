import Foundation
import Observation

/// "..." › Manage your content: your posts (published, pending, declined)
/// or comments in one community, newest or oldest first.
@MainActor
@Observable
final class ManageCommunityContentViewModel {
    var kind: MyCommunityContent.Kind = .posts
    var status: MyCommunityContent.Status = .all
    var newestFirst = true
    private(set) var counts = MyCommunityContent.Counts(published: 0, pending: 0, declined: 0, comments: 0)
    private(set) var posts: [Post] = []
    private(set) var comments: [MyCommunityContent.Comment] = []
    private(set) var isLoading = false
    private(set) var canLoadMore = true
    var errorMessage: String?

    private let communityId: String
    private let repository = CommunityRepository()
    /// Drops a late page from a since-changed filter.
    private var generation = 0

    init(communityId: String) { self.communityId = communityId }

    func count(of status: MyCommunityContent.Status) -> Int {
        switch status {
        case .all: counts.published + counts.pending + counts.declined
        case .published: counts.published
        case .pending: counts.pending
        case .declined: counts.declined
        }
    }

    /// From the top, after any filter change.
    func reload(token: String) async {
        generation += 1
        posts = []
        comments = []
        canLoadMore = true
        await loadMore(token: token)
    }

    func loadMore(token: String) async {
        guard canLoadMore, !isLoading else { return }
        let gen = generation
        isLoading = true
        defer { if gen == generation { isLoading = false } }
        do {
            let page = try await repository.fetchMyContent(
                communityId: communityId, kind: kind, newestFirst: newestFirst, status: status,
                offset: kind == .posts ? posts.count : comments.count, token: token)
            guard gen == generation else { return }
            counts = page.counts
            posts += page.posts
            comments += page.comments
            canLoadMore = (kind == .posts ? page.posts.count : page.comments.count) == 20
        } catch {
            guard gen == generation else { return }
            errorMessage = friendlyError(error)
        }
    }

    func removePost(id: String) { posts.removeAll { $0.id == id } }
}

import Foundation
import Observation

/// Someone's profile within one community: their persona for its mode,
/// connections, role, and only the posts they published there.
@MainActor
@Observable
final class CommunityMemberProfileViewModel {
    private(set) var profile: CommunityMemberProfile?
    private(set) var posts: [Post] = []
    private(set) var isLoading = false
    private(set) var canLoadMore = true
    var errorMessage: String?

    private let communityId: String
    private let userId: String
    private let repository = CommunityRepository()

    init(communityId: String, userId: String) {
        self.communityId = communityId
        self.userId = userId
    }

    func load(token: String) async {
        posts = []
        canLoadMore = true
        await loadMore(token: token)
    }

    func loadMore(token: String) async {
        guard canLoadMore, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await repository.fetchMemberProfile(communityId: communityId, userId: userId,
                                                               offset: posts.count, token: token)
            profile = page
            posts += page.posts
            canLoadMore = page.posts.count == 20
        } catch {
            errorMessage = friendlyError(error)
        }
    }

    func removePost(id: String) { posts.removeAll { $0.id == id } }
}

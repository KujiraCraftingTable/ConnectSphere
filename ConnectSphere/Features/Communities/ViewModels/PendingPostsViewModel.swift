import Foundation
import Observation

/// Admins/moderators: posts waiting for approval.
@MainActor
@Observable
final class PendingPostsViewModel {
    private(set) var posts: [Post] = []
    private(set) var isLoading = false
    private(set) var reviewing: Set<String> = []
    var errorMessage: String?

    private let communityId: String
    private let repository = CommunityRepository()

    init(communityId: String) { self.communityId = communityId }

    func load(token: String) async {
        isLoading = true
        defer { isLoading = false }
        do {
            posts = try await repository.fetchPendingPosts(communityId: communityId, token: token)
        } catch {
            // Pull-to-refresh cancels the request it replaces; that isn't a failure.
            guard !error.isCancellation else { return }
            errorMessage = friendlyError(error)
        }
    }

    /// Approve (it goes live) or decline (with an optional reason).
    func review(_ post: Post, approve: Bool, reason: String?, token: String) async {
        reviewing.insert(post.id)
        defer { reviewing.remove(post.id) }
        let trimmed = reason?.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try await repository.reviewPost(communityId: communityId, postId: post.id, approve: approve,
                                            reason: trimmed?.isEmpty == false ? trimmed : nil, token: token)
            posts.removeAll { $0.id == post.id }
        } catch {
            errorMessage = friendlyError(error)
        }
    }
}

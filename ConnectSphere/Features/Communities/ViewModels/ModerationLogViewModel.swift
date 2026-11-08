import Foundation
import Observation

/// "..." › Moderation log (admin only): what the admin and moderators did.
@MainActor
@Observable
final class ModerationLogViewModel {
    private(set) var entries: [ModLogEntry] = []
    private(set) var isLoading = false
    private(set) var reachedEnd = false
    var errorMessage: String?

    private let communityId: String
    private let repository = CommunityRepository()
    private let pageSize = 30

    init(communityId: String) { self.communityId = communityId }

    func load(token: String) async {
        entries = []
        reachedEnd = false
        await loadMore(token: token)
    }

    func loadMore(token: String) async {
        guard !isLoading, !reachedEnd else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await repository.fetchModLog(communityId: communityId, offset: entries.count,
                                                        limit: pageSize, token: token)
            entries += page
            reachedEnd = page.count < pageSize
        } catch where !error.isCancellation {
            errorMessage = friendlyError(error)
        } catch {}
    }
}

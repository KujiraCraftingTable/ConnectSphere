import Foundation
import Observation

/// The user's drafts (and scheduled posts) — for Settings → Drafts and the
/// composer's Drafts button. Refreshes itself when a draft changes elsewhere.
@MainActor
@Observable
final class DraftsViewModel {
    private(set) var posts: [Post] = []
    private(set) var hasLoaded = false
    var error: String?

    private let repository = DraftRepository()
    private let communities = CommunityRepository()
    nonisolated(unsafe) private var observer: NSObjectProtocol?

    var drafts: [Post] { posts.filter { $0.publishStatus == "draft" } }
    var scheduled: [Post] { posts.filter { $0.publishStatus == "scheduled" } }

    /// Feed drafts (`communityId` nil) or one community's — what a composer offers.
    func drafts(inCommunity communityId: String?) -> [Post] {
        drafts.filter { $0.community?.id.lowercased() == communityId?.lowercased() }
    }

    init() {
        observer = NotificationCenter.default.addObserver(forName: .draftsChanged, object: nil, queue: .main) { [weak self] _ in
            Task { await self?.load() }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func load() async {
        do {
            posts = try await repository.list()
            hasLoaded = true
        } catch {
            if !hasLoaded { self.error = Bundle.app.loc(friendlyError(error)) }
        }
    }

    /// A draft and the composer it belongs in.
    struct Opened: Identifiable {
        enum Place { case feed, community(Community) }
        let draft: Post
        let place: Place
        var id: String { draft.id }
    }

    /// A community draft needs its community to reopen the right composer.
    func open(_ draft: Post) async -> Opened? {
        guard let ref = draft.community else { return Opened(draft: draft, place: .feed) }
        do {
            let token = KeychainHelper.load(forKey: KeychainHelper.tokenKey) ?? ""
            let community = try await communities.fetchDetail(communityId: ref.id, token: token)
            return Opened(draft: draft, place: .community(community))
        } catch {
            self.error = Bundle.app.loc(friendlyError(error))
            return nil
        }
    }

    func delete(_ post: Post) async {
        let before = posts
        posts.removeAll { $0.id == post.id }     // optimistic
        do {
            try await repository.delete(post.id)
        } catch {
            posts = before
            self.error = Bundle.app.loc(friendlyError(error))
        }
    }
}

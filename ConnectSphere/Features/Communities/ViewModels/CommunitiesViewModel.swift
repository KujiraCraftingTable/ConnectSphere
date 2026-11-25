import Foundation
import Observation

@Observable
class CommunitiesViewModel {
    /// This mode's communities. Only for the duplicate-name hint when creating one.
    var discoverCommunities: [Community] = []
    var myCommunities: [Community] = []
    var isLoading = false
    var errorMessage: String?
    /// Separate loading / error state for the "My communities" tab, it must not
    /// borrow `isLoading` (that tracks Discover) and must not swallow failures,
    /// or the tab silently shows "you haven't joined any communities".
    var isLoadingMine = false
    var myError: String?

    private let repository = CommunityRepository()
    private var token: String = ""
    private var searchTask: Task<Void, Never>?

    // MARK: - Loading
    func fetchInitial(token: String, type: CommunityType) async {
        self.token = token
        async let discover: () = loadDiscover(type: type)
        async let mine: ()     = loadMyCommunities()
        _ = await (discover, mine)
    }

    func scheduleSearch(query: String, type: CommunityType) {
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            await self?.loadDiscover(query: query, type: type)
        }
    }

    func loadDiscover(query: String = "", type: CommunityType) async {
        isLoading = true
        errorMessage = nil
        do {
            discoverCommunities = try await repository.fetchCommunities(query: query, type: type, token: token)
        } catch {
            // No alert: this list only feeds the duplicate-name hint, and the
            // screen already shows the connection error inline with Retry
            // (`myError`). An alert on top made the user dismiss it to reach Retry.
            #if DEBUG
            print("Discover list failed: \(error)")
            #endif
        }
        isLoading = false
    }

    func loadMyCommunities() async {
        isLoadingMine = true
        myError = nil
        do {
            myCommunities = try await repository.fetchMyCommunities(token: token)
        } catch {
            myError = friendlyError(error)
        }
        isLoadingMine = false
    }

    // MARK: - Membership
    func join(_ community: Community) async {
        updateMembership(id: community.id, isMember: true, delta: +1)
        do {
            try await repository.join(communityId: community.id, token: token)
            await loadMyCommunities()
        } catch {
            updateMembership(id: community.id, isMember: false, delta: -1)
            errorMessage = friendlyError(error)
        }
    }

    func leave(_ community: Community) async {
        do {
            try await repository.leave(communityId: community.id, token: token)
            myCommunities.removeAll { $0.id == community.id }
            updateMembership(id: community.id, isMember: false, delta: -1)
        } catch {
            errorMessage = friendlyError(error)
        }
    }

    private func updateMembership(id: String, isMember: Bool, delta: Int) {
        if let i = discoverCommunities.firstIndex(where: { $0.id == id }) {
            discoverCommunities[i].isMember    = isMember
            discoverCommunities[i].memberCount = max(0, discoverCommunities[i].memberCount + delta)
        }
    }
}

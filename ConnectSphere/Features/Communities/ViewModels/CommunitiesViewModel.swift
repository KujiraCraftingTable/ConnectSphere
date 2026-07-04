import Foundation
import Observation

@Observable
class CommunitiesViewModel {
    var discoverCommunities: [Community] = []
    var myCommunities: [Community] = []
    var isLoading = false
    var errorMessage: String?

    private let repository = CommunityRepository()
    private var token: String = ""
    private var searchTask: Task<Void, Never>?

    func fetchInitial(token: String) async {
        self.token = token
        async let discover: () = loadDiscover()
        async let mine: ()     = loadMyCommunities()
        _ = await (discover, mine)
    }

    func scheduleSearch(query: String, type: CommunityType?) {
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            await self?.loadDiscover(query: query, type: type)
        }
    }

    func loadDiscover(query: String = "", type: CommunityType? = nil) async {
        isLoading = true
        errorMessage = nil
        do {
            discoverCommunities = try await repository.fetchCommunities(query: query, type: type, token: token)
        } catch {
            errorMessage = friendlyError(error)
        }
        isLoading = false
    }

    func loadMyCommunities() async {
        do {
            myCommunities = try await repository.fetchMyCommunities(token: token)
        } catch {
            // Silent — section stays empty
        }
    }

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

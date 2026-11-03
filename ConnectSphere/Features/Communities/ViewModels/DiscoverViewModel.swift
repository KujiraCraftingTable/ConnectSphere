import Foundation
import Observation

@Observable
class DiscoverViewModel {
    var trending: [Community] = []
    var recommended: [Community] = []
    var isLoading = false
    var errorMessage: String?

    /// Results for the Discover tab's own search box — a real server-side
    /// search (`GET /communities?query=...`), not a client-side filter of
    /// the already-fetched trending/recommended lists (those are just a
    /// curated top-N, not the full browsable set).
    var searchResults: [Community] = []
    var isSearching = false

    private let token: String
    private let repository = CommunityRepository()
    /// Discards a late search response from a since-superseded query (e.g.
    /// typing fast) — same guard shape `SearchViewModel` already uses.
    private var searchGeneration = 0

    init(token: String) {
        self.token = token
    }

    func fetchDiscover(type: CommunityType) async {
        isLoading = true
        errorMessage = nil
        do {
            let result = try await repository.fetchDiscover(type: type, token: token)
            trending    = result.trending
            recommended = result.recommended
        } catch {
            errorMessage = friendlyError(error)
        }
        isLoading = false
    }

    func search(query: String, type: CommunityType) async {
        searchGeneration += 1
        let generation = searchGeneration
        isSearching = true
        do {
            let results = try await repository.fetchCommunities(query: query, type: type, token: token)
            guard generation == searchGeneration else { return }
            searchResults = results
        } catch {
            guard generation == searchGeneration else { return }
            errorMessage = friendlyError(error)
        }
        if generation == searchGeneration { isSearching = false }
    }

    /// Join/leave straight from any row (trending, recommended or a search
    /// result) — optimistic, reverted on failure.
    func toggleMembership(_ community: Community) async {
        let joining = !community.isMember
        updateSearchMembership(id: community.id, isMember: joining, delta: joining ? 1 : -1)
        do {
            if joining {
                try await repository.join(communityId: community.id, token: token)
            } else {
                try await repository.leave(communityId: community.id, token: token)
            }
        } catch {
            updateSearchMembership(id: community.id, isMember: !joining, delta: joining ? -1 : 1)
            errorMessage = friendlyError(error)
        }
    }

    private func updateSearchMembership(id: String, isMember: Bool, delta: Int) {
        for keyPath in [\DiscoverViewModel.trending, \.recommended, \.searchResults] {
            guard let i = self[keyPath: keyPath].firstIndex(where: { $0.id == id }) else { continue }
            self[keyPath: keyPath][i].isMember = isMember
            self[keyPath: keyPath][i].memberCount = max(0, self[keyPath: keyPath][i].memberCount + delta)
        }
    }
}

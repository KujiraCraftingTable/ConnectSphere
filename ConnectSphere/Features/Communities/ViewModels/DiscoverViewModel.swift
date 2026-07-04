import Foundation
import Observation

@Observable
class DiscoverViewModel {
    var trending: [Community] = []
    var recommended: [Community] = []
    var isLoading = false
    var errorMessage: String?

    private let token: String
    private let repository = CommunityRepository()

    init(token: String) {
        self.token = token
    }

    func fetchDiscover(type: CommunityType? = nil) async {
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

    func refreshRecommendations() async {
        do {
            recommended = try await repository.fetchRecommendations(token: token)
        } catch {
            errorMessage = friendlyError(error)
        }
    }
}

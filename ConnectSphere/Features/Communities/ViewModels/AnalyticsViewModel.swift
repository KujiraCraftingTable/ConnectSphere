import Foundation
import Observation

@Observable
class AnalyticsViewModel {
    var analytics: CommunityAnalytics?
    var selectedPeriod: Int = 30
    var isLoading = false
    var errorMessage: String?

    private let token: String
    private let repository = CommunityRepository()

    init(token: String) {
        self.token = token
    }

    func fetchAnalytics(communityId: String) async {
        isLoading = true
        errorMessage = nil
        do {
            analytics = try await repository.fetchAnalytics(
                communityId: communityId, days: selectedPeriod, token: token
            )
        } catch {
            errorMessage = friendlyError(error)
        }
        isLoading = false
    }
}

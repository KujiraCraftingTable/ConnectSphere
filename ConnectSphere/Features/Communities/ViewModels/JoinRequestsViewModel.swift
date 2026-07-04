import Foundation
import Observation

@Observable
class JoinRequestsViewModel {
    var requests: [JoinRequest] = []
    var isLoading = false
    var errorMessage: String?

    private let communityId: String
    private let token: String
    private let repository = CommunityRepository()

    init(communityId: String, token: String) {
        self.communityId = communityId
        self.token       = token
    }

    func fetchRequests() async {
        isLoading = true
        do {
            requests = try await repository.fetchJoinRequests(communityId: communityId, token: token)
        } catch {
            errorMessage = friendlyError(error)
        }
        isLoading = false
    }

    func approve(_ requestId: String) async { await review(requestId: requestId, status: "approved") }
    func reject(_ requestId: String)  async { await review(requestId: requestId, status: "rejected") }

    private func review(requestId: String, status: String) async {
        requests.removeAll { $0.id == requestId }
        do {
            try await repository.reviewJoinRequest(
                communityId: communityId, requestId: requestId, status: status, token: token
            )
        } catch {
            errorMessage = friendlyError(error)
            await fetchRequests()
        }
    }
}

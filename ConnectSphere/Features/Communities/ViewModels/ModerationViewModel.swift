import Foundation
import Observation

@Observable
class ModerationViewModel {
    var pendingReports:  [ModerationItem] = []
    var resolvedReports: [ModerationItem] = []
    var pendingCount: Int = 0
    var isLoading = false
    var errorMessage: String?

    private let communityId: String
    private let token: String
    private let repository = CommunityRepository()

    init(communityId: String, token: String) {
        self.communityId = communityId
        self.token       = token
    }

    func fetchQueue(status: String = "pending") async {
        isLoading = true
        do {
            let result = try await repository.fetchModerationQueue(
                communityId: communityId, status: status, token: token
            )
            if status == "pending" { pendingReports  = result.reports }
            else                   { resolvedReports = result.reports }
            pendingCount = result.pendingCount
        } catch {
            errorMessage = friendlyError(error)
        }
        isLoading = false
    }

    func removeContent(_ reportId: String) async { await resolve(reportId: reportId, action: "remove_content") }
    func banMember(_ reportId: String)     async { await resolve(reportId: reportId, action: "ban_member") }
    func dismiss(_ reportId: String)       async { await resolve(reportId: reportId, action: "dismiss") }

    private func resolve(reportId: String, action: String) async {
        pendingReports.removeAll { $0.id == reportId }
        pendingCount = max(0, pendingCount - 1)
        do {
            try await repository.resolveReport(
                communityId: communityId, reportId: reportId, action: action, token: token
            )
        } catch {
            errorMessage = friendlyError(error)
            await fetchQueue()
        }
    }
}

import Foundation
import Observation

// MARK: - Report queue
/// A community's Reports screen: reported posts and members, one case each.
@MainActor
@Observable
final class CommunityReportsViewModel {
    private(set) var pending: [CommunityReportCase] = []
    private(set) var resolved: [CommunityReportCase] = []
    private(set) var pendingCount = 0
    /// Only the admin bans. Given by the community page; looked up when opened from a notification.
    private(set) var isAdmin: Bool?
    private(set) var isLoading = false
    var errorMessage: String?

    let communityId: String
    private let repository = CommunityRepository()

    init(communityId: String, isAdmin: Bool?) {
        self.communityId = communityId
        self.isAdmin = isAdmin
    }

    func loadRoleIfNeeded(token: String) async {
        guard isAdmin == nil else { return }
        isAdmin = (try? await repository.fetchDetail(communityId: communityId, token: token))?.role == .admin
    }

    func load(resolved showResolved: Bool, token: String) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let queue = try await repository.fetchReportCases(communityId: communityId, resolved: showResolved, token: token)
            if showResolved { resolved = queue.cases } else { pending = queue.cases }
            pendingCount = queue.pendingCount
        } catch {
            guard !error.isCancellation else { return }
            errorMessage = friendlyError(error)
        }
    }

    /// A case decided on its own screen leaves the pending list right away.
    func caseDecided(_ targetId: String) {
        pending.removeAll { $0.targetId == targetId }
        pendingCount = max(0, pendingCount - 1)
    }
}

// MARK: - Report case
/// One case: its reports, history, and the decision.
@MainActor
@Observable
final class CommunityReportCaseViewModel {
    private(set) var detail: CommunityReportDetail?
    private(set) var isLoading = false
    private(set) var isDeciding = false
    var errorMessage: String?

    let communityId: String
    let targetId: String
    private let repository = CommunityRepository()

    init(communityId: String, targetId: String) {
        self.communityId = communityId
        self.targetId = targetId
    }

    func load(token: String) async {
        isLoading = true
        defer { isLoading = false }
        do {
            detail = try await repository.fetchReportCase(communityId: communityId, targetId: targetId, token: token)
        } catch {
            guard !error.isCancellation else { return }
            errorMessage = friendlyError(error)
        }
    }

    /// True once the decision is saved; the screen then closes.
    func decide(_ decision: CommunityReportDecision, note: String, token: String) async -> Bool {
        isDeciding = true
        defer { isDeciding = false }
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try await repository.decideReportCase(communityId: communityId, targetId: targetId, decision: decision,
                                                  note: trimmed.isEmpty ? nil : trimmed, token: token)
            return true
        } catch {
            errorMessage = friendlyError(error)
            return false
        }
    }
}

import Foundation
import Observation

/// Admin tools › HR requests: the queue and the decided ones.
@MainActor
@Observable
final class HRRequestsViewModel {
    enum Tab: String, CaseIterable { case pending, approved, rejected, revoked }

    var tab: Tab = .pending
    private(set) var requests: [HRRequestItem] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private let repository = HRAdminRepository()

    func load(token: String) async {
        isLoading = true
        defer { isLoading = false }
        do {
            requests = try await repository.requests(status: tab.rawValue, token: token)
            errorMessage = nil
        } catch {
            errorMessage = friendlyError(error)
        }
    }
}

/// One request: the checks the reviewer confirms, then approve or reject.
@MainActor
@Observable
final class HRRequestDetailViewModel {
    /// What the reviewer confirms before approving; all must be ticked.
    static let checks: [(key: String, label: String)] = [
        ("email_verified", "The company email was verified by code"),
        ("tax_code_registry", "The tax code is in the national business registry"),
        ("name_matches_licence", "The company name matches the business registration"),
        ("domain_matches_website", "The email domain is the company's real website"),
    ]

    private(set) var request: HRRequestItem
    var checklist: [String: Bool]
    var note = ""
    private(set) var isWorking = false
    private(set) var errorMessage: String?
    private let repository = HRAdminRepository()

    init(request: HRRequestItem) {
        self.request = request
        // Verifying the code is the server's job: it's always done by now.
        checklist = request.checklist ?? ["email_verified": true]
    }

    private var trimmedNote: String? {
        let n = note.trimmingCharacters(in: .whitespacesAndNewlines)
        return n.isEmpty ? nil : n
    }

    var canApprove: Bool {
        request.status == "pending" && request.conflictWith == nil && !isWorking
            && Self.checks.allSatisfy { checklist[$0.key] == true }
    }
    var canReject: Bool { request.status == "pending" && trimmedNote != nil && !isWorking }
    var canRevoke: Bool { request.status == "approved" && trimmedNote != nil && !isWorking }

    func isChecked(_ key: String) -> Bool { checklist[key] == true }
    func setChecked(_ key: String, _ on: Bool) { checklist[key] = on }

    /// Returns true once decided.
    func decide(approve: Bool, token: String) async -> Bool {
        guard approve ? canApprove : canReject else { return false }
        isWorking = true
        defer { isWorking = false }
        do {
            request = try await repository.decide(request.id, approve: approve, checklist: checklist,
                                                  note: trimmedNote, token: token)
            errorMessage = nil
            return true
        } catch {
            errorMessage = friendlyError(error)
            return false
        }
    }

    /// Takes HR away: their jobs are removed and applicants told. Returns true once done.
    func revoke(token: String) async -> Bool {
        guard canRevoke, let note = trimmedNote else { return false }
        isWorking = true
        defer { isWorking = false }
        do {
            try await repository.revoke(userId: request.person.id, note: note, token: token)
            errorMessage = nil
            return true
        } catch {
            errorMessage = friendlyError(error)
            return false
        }
    }
}

/// Admin tools › Jobs to review: a new HR's first jobs, before they go live.
@MainActor
@Observable
final class PendingJobsViewModel {
    private(set) var jobs: [PendingJobItem] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    /// Declining needs a reason the HR reads.
    var declineReason = ""
    private(set) var workingOn: String?
    private let repository = HRAdminRepository()

    func load(token: String) async {
        isLoading = true
        defer { isLoading = false }
        do {
            jobs = try await repository.pendingJobs(token: token)
            errorMessage = nil
        } catch {
            errorMessage = friendlyError(error)
        }
    }

    var canDecline: Bool { !declineReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    func decide(_ job: PendingJobItem, approve: Bool, token: String) async {
        let reason = declineReason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard approve || !reason.isEmpty else { return }
        workingOn = job.id
        defer { workingOn = nil }
        do {
            try await repository.decideJob(job.postId, approve: approve, reason: approve ? nil : reason, token: token)
            jobs.removeAll { $0.id == job.id }
            declineReason = ""
            errorMessage = nil
        } catch {
            errorMessage = friendlyError(error)
        }
    }
}

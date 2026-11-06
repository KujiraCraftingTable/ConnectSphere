import Foundation
import Observation

/// Reporting a community member (or a post in the community) with a reason
/// and optional detail.
@MainActor
@Observable
final class ReportViewModel {
    var selectedReason: ReportReason?
    var detail = ""
    private(set) var isSubmitting = false
    private(set) var submitted = false
    private(set) var errorMessage: String?

    private let repository = CommunityRepository()

    var canSubmit: Bool { selectedReason != nil && !isSubmitting }

    /// A reason picked or a note typed, and not sent yet, Cancel asks then.
    var hasChanges: Bool {
        !submitted && (selectedReason != nil || !detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    func submit(targetType: String, targetId: String, communityId: String, token: String) async {
        guard let reason = selectedReason else { return }
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }
        let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try await repository.report(targetType: targetType, targetId: targetId, communityId: communityId,
                                        reason: reason.rawValue, detail: trimmed.isEmpty ? nil : trimmed,
                                        token: token)
            submitted = true
        } catch {
            if case APIError.serverError(_, let message) = error { errorMessage = message }
            else { errorMessage = Bundle.app.loc("Could not submit report. Please try again.") }
        }
    }
}

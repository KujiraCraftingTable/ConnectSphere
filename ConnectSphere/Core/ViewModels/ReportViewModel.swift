import Foundation
import Observation

/// One report: a reason, optional detail, then — like Instagram and X —
/// a chance to block the person straight away.
@MainActor
@Observable
final class ReportViewModel {
    let subject: ReportSubject
    var selectedReason: ModerationReason?
    var detail = ""
    private(set) var isSubmitting = false
    private(set) var submitted = false
    private(set) var blocked = false
    private(set) var errorMessage: String?

    private let repository = ReportRepository()
    private let users = UserRepository()

    init(subject: ReportSubject) { self.subject = subject }

    static let maxDetail = 500

    var canSubmit: Bool { selectedReason != nil && !isSubmitting && detail.count <= Self.maxDetail }

    func submit() async {
        guard let reason = selectedReason else { return }
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }
        let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try await repository.submit(subject, reason: reason, detail: trimmed.isEmpty ? nil : trimmed)
            submitted = true
        } catch APIError.serverError(409, _) {
            // Already reported: as far as the person is concerned, it's done.
            submitted = true
        } catch APIError.serverError(404, _) {
            errorMessage = Bundle.app.loc("This content is no longer available")
        } catch {
            errorMessage = friendlyError(error)
        }
    }

    func block(userId: String) async {
        do {
            try await users.blockUser(userId: userId)
            blocked = true
            NotificationCenter.default.post(name: .userBlockStatusChanged, object: nil, userInfo: ["userId": userId])
        } catch {
            errorMessage = friendlyError(error)
        }
    }
}

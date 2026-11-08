import Foundation
import Observation

/// The app-wide review queue: open cases from reports, ones the automatic
/// checks held, and appeals waiting for a second look.
@MainActor
@Observable
final class ModerationQueueViewModel {
    enum Tab: String, CaseIterable { case reports, auto, appeals }

    var tab: Tab = .reports
    private(set) var cases: [ModerationCase] = []
    private(set) var appeals: [ModerationAppealItem] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    private let repository = ModerationRepository()

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            switch tab {
            case .reports: cases = try await repository.cases(source: "report")
            case .auto: cases = try await repository.cases(source: "auto")
            case .appeals: appeals = try await repository.appeals()
            }
        } catch {
            errorMessage = friendlyError(error)
        }
    }

    /// Vietnam's Decree 147 expects user complaints handled within about two
    /// days; anything older than a day is shown as overdue.
    static func isOverdue(_ created: Date, now: Date = Date()) -> Bool {
        now.timeIntervalSince(created) > 24 * 3600
    }
}

/// One case in full, and the decision on it (or on its appeal).
@MainActor
@Observable
final class ModerationCaseViewModel {
    let caseId: String
    private(set) var detail: ModerationCaseDetail?
    private(set) var isLoading = false
    private(set) var isWorking = false
    private(set) var errorMessage: String?
    var note = ""

    static let restrictOptions = [1, 3, 7, 30]

    private let repository = ModerationRepository()

    init(caseId: String) { self.caseId = caseId }

    var isOpen: Bool { detail?.case.status == "open" }
    var pendingAppeal: ModerationAppeal? { detail?.appeal.flatMap { $0.status == "pending" ? $0 : nil } }

    func load() async {
        isLoading = detail == nil
        errorMessage = nil
        defer { isLoading = false }
        do { detail = try await repository.caseDetail(caseId) }
        catch { errorMessage = friendlyError(error) }
    }

    private var trimmedNote: String? {
        let n = note.trimmingCharacters(in: .whitespacesAndNewlines)
        return n.isEmpty ? nil : n
    }

    func decide(_ decision: ModerationDecisionKind, days: Int? = nil) async {
        await work { try await self.repository.decide(caseId: self.caseId, decision: decision, days: days, note: self.trimmedNote) }
    }

    func decideAppeal(overturn: Bool) async {
        guard let appeal = pendingAppeal else { return }
        await work { try await self.repository.decideAppeal(appeal.id, overturn: overturn, note: self.trimmedNote) }
    }

    private func work(_ call: @escaping () async throws -> ModerationCaseDetail) async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            detail = try await call()
            note = ""
            NotificationCenter.default.post(name: .moderationCaseDecided, object: nil)
        } catch {
            errorMessage = friendlyError(error)
        }
    }
}

extension Notification.Name {
    /// The queue reloads when a case it lists has been decided.
    static let moderationCaseDecided = Notification.Name("moderationCaseDecided")
}

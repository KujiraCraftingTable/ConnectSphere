import Foundation
import Observation

/// Settings › Account status, like Meta's: whether you're restricted or
/// banned, your strikes, what was removed and why (with a way to ask for a
/// review), and how the reports you made turned out.
@MainActor
@Observable
final class AccountStatusViewModel {
    private(set) var status: AccountStatus?
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    /// The decision an appeal is being written for.
    var appealing: AccountStatus.Decision?
    var appealMessage = ""
    private(set) var isSendingAppeal = false
    private(set) var appealError: String?

    static let maxAppealLength = 1000

    private let repository = ModerationRepository()

    func load() async {
        isLoading = status == nil
        errorMessage = nil
        defer { isLoading = false }
        do { status = try await repository.accountStatus() }
        catch { errorMessage = friendlyError(error) }
    }

    var canSendAppeal: Bool { !isSendingAppeal && appealMessage.count <= Self.maxAppealLength }

    /// True once sent; the sheet then closes.
    func sendAppeal() async -> Bool {
        guard let decision = appealing else { return false }
        isSendingAppeal = true
        appealError = nil
        defer { isSendingAppeal = false }
        let text = appealMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try await repository.appeal(caseId: decision.caseId, message: text.isEmpty ? nil : text)
            appealing = nil
            appealMessage = ""
            await load()
            return true
        } catch {
            appealError = friendlyError(error)
            return false
        }
    }
}

/// Whether Settings shows the Moderation row: only app moderators and admins.
@MainActor
@Observable
final class ModerationEntryViewModel {
    private(set) var isStaff = false
    /// Also shows Admin tools: only the official account.
    private(set) var isAdmin = false
    private let repository = ModerationRepository()

    func load() async {
        let status = try? await repository.accountStatus()
        isStaff = status?.isStaff ?? false
        isAdmin = status?.isAdmin ?? false
    }
}

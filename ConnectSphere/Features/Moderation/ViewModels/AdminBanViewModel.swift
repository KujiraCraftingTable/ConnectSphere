import Foundation
import Observation

/// What the official account is acting on: an item and whose it is.
struct ModerationTarget: Identifiable, Hashable {
    /// "user", "post", "comment" or "message".
    let type: String
    let id: String
    /// The person the warning or ban lands on.
    let userId: String
    let userName: String
    /// The persona being acted on: a profile's mode, a post's or comment's mode.
    /// nil for a message (it counts in both modes).
    let mode: String?
}

/// The official account warning or banning from a post, comment, message or
/// profile (migration 106). Three active warnings in a mode turn into a ban,
/// so a third warning becomes a ban whose length the admin picks.
@MainActor
@Observable
final class AdminBanViewModel {
    enum Action: String, CaseIterable { case warn, ban }
    /// Reasons that justify acting on an account (not off-topic or misinformation).
    static let reasons: [ModerationReason] = [.scam, .spam, .harassment, .hate, .impersonation, .underage,
                                              .childSafety, .nuditySexual, .violence, .illegalGoods, .other]
    /// Ban lengths; nil is permanent.
    static let durations: [Int?] = [7, 30, 90, 365, nil]
    static let warningsForBan = 3

    let target: ModerationTarget
    var action: Action = .warn
    var reason: ModerationReason = .spam
    var days: Int? = 7
    var note = ""
    private(set) var activeWarnings: Int?
    private(set) var isSending = false
    private(set) var done: Action?
    var errorMessage: String?

    private let repository = ModerationRepository()

    init(target: ModerationTarget) { self.target = target }

    /// The next warning would be the third: only a ban is possible.
    var mustBan: Bool { (activeWarnings ?? 0) + 1 >= Self.warningsForBan }

    func load() async {
        let count = try? await repository.warningCount(userId: target.userId, mode: target.mode ?? "hobby")
        activeWarnings = count?.activeWarnings
        if mustBan { action = .ban }
    }

    func submit() async {
        guard !isSending else { return }
        isSending = true
        defer { isSending = false }
        do {
            _ = try await repository.moderate(action: action.rawValue, targetType: target.type, targetId: target.id,
                                              mode: target.type == "user" ? target.mode : nil,
                                              policy: reason.rawValue, days: action == .ban ? days : nil,
                                              note: note.trimmingCharacters(in: .whitespacesAndNewlines))
            done = action
            // A warned or banned post is taken down: its card turns into a
            // "Post removed" placeholder (no Undo) wherever it's on screen.
            if target.type == "post" {
                HiddenPostsRegistry.shared.set(.moderated(banned: action == .ban), for: target.id)
            }
        } catch let APIError.serverError(status, message) where status == 409 && message == "third_warning" {
            // Someone else warned them meanwhile: this one must be a ban.
            activeWarnings = Self.warningsForBan - 1
            action = .ban
            errorMessage = Bundle.app.loc("This would be their third warning, so it has to be a ban. Pick how long.")
        } catch {
            errorMessage = friendlyError(error)
        }
    }
}

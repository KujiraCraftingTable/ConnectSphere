import Foundation
import Observation

/// First-run profile setup: four steps (mode → basics → interests/skills →
/// bio), then `AppState.completeOnboarding`.
@MainActor
@Observable
final class OnboardingViewModel {
    static let totalSteps = 4

    private(set) var step = 0
    /// Which way the last step change went — drives the slide direction.
    private(set) var movedForward = true
    var form = OnboardingForm()
    var selectedInterests: [InterestItem] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    /// Google accounts get a placeholder `user_xxxxxxxx` at sign-in and were
    /// never asked for a name, so they choose one here. Password sign-ups
    /// already picked theirs at registration.
    private(set) var needsUsername = false

    enum UsernameStatus: Equatable { case idle, checking, available, taken, failed }
    private(set) var usernameStatus: UsernameStatus = .idle

    func prefill(username: String?, hasPassword: Bool) {
        guard form.username.isEmpty, !needsUsername else { return }
        if hasPassword {
            form.username = username ?? ""
        } else {
            needsUsername = true
        }
    }

    /// The username typed so far, lowercased like at registration.
    var username: String {
        get { form.username }
        set { form.username = newValue.lowercased() }
    }

    var usernameProblem: String? { UsernameRules.problem(form.username) }

    /// Debounced server check; the view restarts it (cancelling the last one)
    /// on every edit via `.task(id:)`.
    func checkUsername(token: String?) async {
        guard needsUsername else { return }
        guard UsernameRules.isValid(form.username), let token else { usernameStatus = .idle; return }
        usernameStatus = .checking
        try? await Task.sleep(for: .milliseconds(400))
        guard !Task.isCancelled else { return }
        do {
            let name = form.username
            let available = try await AuthService.shared.isUsernameAvailable(name, token: token)
            guard !Task.isCancelled, name == form.username else { return }
            usernameStatus = available ? .available : .taken
        } catch {
            if !Task.isCancelled { usernameStatus = .failed }
        }
    }

    /// Step 2's required fields. Forward navigation (button or swipe) checks
    /// `canAdvance`, so an incomplete form can't be submitted.
    var basicsComplete: Bool {
        !form.display_name.trimmingCharacters(in: .whitespaces).isEmpty
            && !form.username.isEmpty
            && (!needsUsername || usernameStatus == .available)
            && !form.location.isEmpty
            && !form.gender.isEmpty
            && !form.dob.isEmpty
    }

    var canAdvance: Bool {
        guard step < Self.totalSteps - 1 else { return false }
        return step == 1 ? basicsComplete : true
    }

    var canGoBack: Bool { step > 0 }

    /// Skills edited as one comma-separated line.
    var skillsText: String {
        get { form.skills.joined(separator: ", ") }
        set {
            form.skills = newValue.components(separatedBy: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
    }

    /// Returns false (and stays put) when the current step isn't complete.
    @discardableResult
    func next() -> Bool {
        guard canAdvance else { return false }
        movedForward = true
        step += 1
        return true
    }

    func back() {
        guard canGoBack else { return }
        movedForward = false
        step -= 1
    }

    func finish(appState: AppState) async {
        form.interests = selectedInterests.map { $0.displayText }
        isLoading = true
        errorMessage = nil
        do {
            try await appState.completeOnboarding(form: form)
        } catch {
            errorMessage = friendlyError(error)
        }
        isLoading = false
    }
}

import Foundation
import Observation

/// First-run profile setup: four steps (mode → basics → interests/skills →
/// bio), then `AppState.completeOnboarding`.
@MainActor
@Observable
final class OnboardingViewModel {
    static let totalSteps = 4

    private(set) var step = 0
    var form = OnboardingForm() {
        didSet {
            if form.display_name.count > DisplayNameRules.maxLength {
                form.display_name = DisplayNameRules.capped(form.display_name)
            }
        }
    }
    var selectedInterests: [InterestItem] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    /// A manual sign-up not created yet: finishing creates the account.
    let pending: PendingSignup?
    /// Someone took the chosen @username before this one finished.
    private(set) var usernameLost = false

    init(pending: PendingSignup? = nil, policyMemory: PolicyConsentMemory = PolicyConsentMemory()) {
        self.pending = pending
        asksForPolicy = pending == nil && !policyMemory.acceptsCurrent
        if let pending { form.username = pending.username }
    }

    /// Google accounts get a placeholder `user_xxxxxxxx` at sign-in and were
    /// never asked for a name, so they choose one here. Password sign-ups
    /// already picked theirs at registration.
    private(set) var needsUsername = false

    enum UsernameStatus: Equatable { case idle, checking, available, taken, failed }
    private(set) var usernameStatus: UsernameStatus = .idle

    /// A Google sign-up has no password; it's offered one here (optional) so
    /// it can also sign in with @username / email + password.
    private(set) var offersPassword = false
    var newPassword = ""
    var confirmNewPassword = ""

    /// A password sign-up ticked the Terms/Privacy box on the sign-up form, and a
    /// Google sign-in on the login screen (remembered for this edition on this
    /// phone). Only a Google account that somehow got here without a tick is asked.
    let asksForPolicy: Bool
    var acceptsPolicy = false

    /// Set once a forward move was refused, from then on the step lists
    /// what's still missing.
    private(set) var showsMissing = false

    func prefill(username: String?, hasPassword: Bool) {
        guard pending == nil, form.username.isEmpty, !needsUsername else { return }
        if hasPassword {
            form.username = username ?? ""
        } else {
            needsUsername = true
            offersPassword = true
        }
    }

    /// nil when nothing's typed (it's optional) or it's fine.
    var newPasswordProblem: String? {
        guard offersPassword, !(newPassword.isEmpty && confirmNewPassword.isEmpty) else { return nil }
        if newPassword.count < RegisterViewModel.minPassword {
            return Bundle.app.loc("Password must be at least 8 characters")
        }
        return newPassword == confirmNewPassword ? nil : Bundle.app.loc("Passwords don't match")
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

    /// What step 2 still needs, by name. Shown after a refused Continue
    /// or swipe, so it's never a mystery why it won't go on.
    var missingBasics: [String] {
        var missing: [String] = []
        if form.username.isEmpty || (needsUsername && usernameStatus != .available) {
            missing.append(Bundle.app.loc("a free username"))
        }
        if form.display_name.trimmingCharacters(in: .whitespaces).isEmpty { missing.append(Bundle.app.loc("display name")) }
        if form.location.isEmpty { missing.append(Bundle.app.loc("province")) }
        if form.gender.isEmpty { missing.append(Bundle.app.loc("gender")) }
        if form.dob.isEmpty { missing.append(Bundle.app.loc("date of birth")) }
        if asksForPolicy && !acceptsPolicy { missing.append(Bundle.app.loc("your agreement to the Terms and Privacy Policy")) }
        if newPasswordProblem != nil { missing.append(Bundle.app.loc("a valid password (or leave it empty)")) }
        return missing
    }

    /// Step 2's required fields. Forward navigation (button or swipe) checks
    /// `canAdvance`, so an incomplete form can't be submitted.
    var basicsComplete: Bool { missingBasics.isEmpty }

    /// "Still needed: province, gender" once a move was refused.
    var stillNeeded: String? {
        guard showsMissing, step == 1, !missingBasics.isEmpty else { return nil }
        return String(format: Bundle.app.loc("Still needed: %@"), missingBasics.joined(separator: ", "))
    }

    var canAdvance: Bool {
        guard step < Self.totalSteps - 1 else { return false }
        return step == 1 ? basicsComplete : true
    }

    /// How many steps can be swiped to: past the basics only once they're done.
    var reachableSteps: Int { basicsComplete ? Self.totalSteps : 2 }

    func refusedMove() { showsMissing = true }

    var canGoBack: Bool { step > 0 }

    /// Returns false (and stays put) when the current step isn't complete.
    @discardableResult
    func next() -> Bool {
        guard canAdvance else { return false }
        step += 1
        return true
    }

    func back() {
        guard canGoBack else { return }
        step -= 1
    }

    /// The carousel settled on `page` (never past what's reachable).
    func show(step page: Int) {
        step = min(max(page, 0), reachableSteps - 1)
    }

    func finish(appState: AppState) async {
        form.interests = selectedInterests.map { $0.displayText }
        form.accepted_policy_version = pending?.acceptedPolicyVersion
            ?? (asksForPolicy ? (acceptsPolicy ? LegalDocs.version : nil) : LegalDocs.version)
        isLoading = true
        errorMessage = nil
        do {
            if let pending {
                // The account and its @username come into being only now.
                try await appState.registerAndSetUp(pending, form: form)
            } else {
                // Before the profile, so a failure keeps them here to fix it.
                if offersPassword, !newPassword.isEmpty, newPasswordProblem == nil, let token = appState.authToken {
                    try await AuthService.shared.changePassword(token: token, currentPassword: nil, newPassword: newPassword)
                    appState.currentUser?.hasPassword = true
                }
                try await appState.completeOnboarding(form: form)
            }
        } catch {
            if let pending, (error as NSError).code == 409, error.localizedDescription.contains("Username") {
                usernameLost = true
                errorMessage = String(format: Bundle.app.loc("Someone just took @%@. Go back and pick another username."),
                                      pending.username)
            } else {
                errorMessage = friendlyError(error)
            }
        }
        isLoading = false
    }
}

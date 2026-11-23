import Foundation
import Observation

/// Sign-up with @username + password and an optional email, with live
/// per-field validation (the username is checked against the server as it's
/// typed). With an email, a 6-digit code confirms it first. Nothing is
/// created here: this ends in a `PendingSignup`, and the account (and its
/// @username) only exists once onboarding finishes.
@MainActor
@Observable
final class RegisterViewModel {
    static let minPassword = 8

    enum Stage: Equatable { case details, code }

    /// Lowercased as typed. The only silent normalization; anything else
    /// invalid is surfaced as a live hint so the user sees why.
    var username = "" {
        didSet { if username != username.lowercased() { username = username.lowercased() } }
    }
    var password = ""
    var confirmPassword = ""
    /// Optional.
    var email = ""
    /// The age and Terms/Privacy tick, required before anything is sent or
    /// created. It is ticked on the login screen, the only place the box is
    /// shown, since Sign up waits for it there (Law 91/2025 Art. 9: consent
    /// must be an explicit act, never a pre-ticked box).
    var acceptsPolicy: Bool

    init(policyMemory: PolicyConsentMemory = PolicyConsentMemory()) {
        acceptsPolicy = policyMemory.acceptsCurrent
    }
    var code = "" { didSet { if code != AccountCode.clean(code) { code = AccountCode.clean(code) } } }
    private(set) var stage: Stage = .details
    /// Set when the form is done. The view opens onboarding with it.
    var pending: PendingSignup?

    enum UsernameStatus: Equatable { case idle, checking, available, taken, failed }
    /// Set by `checkUsername` (settable here so tests can stand in for the server).
    var usernameStatus: UsernameStatus = .idle
    private(set) var resendAt: Date?
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    // MARK: Live validation (nil = fine, or nothing typed yet)

    private var trimmedUsername: String { username.trimmingCharacters(in: .whitespaces) }
    private var trimmedEmail: String { email.trimmingCharacters(in: .whitespaces).lowercased() }
    var hasEmail: Bool { !trimmedEmail.isEmpty }

    /// Where the code went, masked.
    var maskedEmail: String { AccountCode.mask(trimmedEmail) }

    var usernameError: String? { UsernameRules.problem(username) }

    var usernameHint: String { usernameError ?? UsernameRules.hint }

    /// Debounced server check; the view restarts it (cancelling the last one)
    /// on every edit via `.task(id:)`.
    func checkUsername() async {
        let name = trimmedUsername
        guard UsernameRules.isValid(name) else { usernameStatus = .idle; return }
        usernameStatus = .checking
        try? await Task.sleep(for: .milliseconds(400))
        guard !Task.isCancelled else { return }
        do {
            let available = try await AuthService.shared.usernameAvailable(name)
            guard !Task.isCancelled, name == trimmedUsername else { return }
            usernameStatus = available ? .available : .taken
        } catch {
            if !Task.isCancelled { usernameStatus = .failed }
        }
    }

    /// Shaped like an address (the server checks it properly).
    static func looksLikeEmail(_ s: String) -> Bool {
        let parts = s.split(separator: "@", omittingEmptySubsequences: false)
        return parts.count == 2 && !parts[0].isEmpty && parts[1].contains(".") && !parts[1].hasSuffix(".") && !s.contains(" ")
    }

    var emailError: String? {
        guard hasEmail else { return nil }
        return Self.looksLikeEmail(trimmedEmail) ? nil : Bundle.app.loc("Enter a valid email address")
    }

    var emailHint: String {
        emailError ?? Bundle.app.loc("Optional. Add one to reset your password and use two-factor sign-in, we'll send it a code.")
    }

    var passwordError: String? {
        guard !password.isEmpty else { return nil }
        return password.count < Self.minPassword ? Bundle.app.loc("Password must be at least 8 characters") : nil
    }

    var passwordHint: String {
        passwordError ?? Bundle.app.loc("At least 8 characters. Add symbols like !@#$%^&*_ for extra security.")
    }

    var confirmError: String? {
        guard !confirmPassword.isEmpty, confirmPassword != password else { return nil }
        return Bundle.app.loc("Passwords don't match")
    }

    var isFormValid: Bool {
        UsernameRules.isValid(trimmedUsername)
            && usernameStatus == .available
            && emailError == nil
            && password.count >= Self.minPassword
            && !confirmPassword.isEmpty && confirmPassword == password
            && acceptsPolicy
    }

    // MARK: Submit

    /// No email: straight on to onboarding. An email: a code is sent first.
    func register() async {
        guard acceptsPolicy else { errorMessage = Bundle.app.loc("Please tick to agree before continuing"); return }
        if let problem = UsernameRules.problem(trimmedUsername) ?? (trimmedUsername.isEmpty ? UsernameRules.hint : nil) {
            errorMessage = problem; return
        }
        if let emailError { errorMessage = emailError; return }
        guard password.count >= Self.minPassword else {
            errorMessage = Bundle.app.loc("Password must be at least 8 characters"); return
        }
        guard password == confirmPassword else {
            errorMessage = Bundle.app.loc("Passwords don't match"); return
        }
        isLoading = true
        errorMessage = nil
        do {
            if hasEmail {
                try await AuthService.shared.registerCode(username: trimmedUsername, email: trimmedEmail)
                code = ""
                resendAt = Date().addingTimeInterval(AccountCode.resendSeconds)
                stage = .code
                isLoading = false
            } else {
                isLoading = false
                pending = PendingSignup(username: trimmedUsername, password: password, email: nil,
                                        acceptedPolicyVersion: LegalDocs.version)
            }
        } catch {
            isLoading = false
            errorMessage = AuthErrorText.register(error)
        }
    }

    /// Runs by itself once all 6 digits are in.
    func submitCode() async {
        guard stage == .code, code.count == 6, !isLoading else { return }
        isLoading = true
        errorMessage = nil
        do {
            try await AuthService.shared.registerVerify(email: trimmedEmail, code: code)
            isLoading = false
            pending = PendingSignup(username: trimmedUsername, password: password, email: trimmedEmail,
                                    acceptedPolicyVersion: LegalDocs.version)
        } catch {
            isLoading = false
            code = ""
            errorMessage = AuthErrorText.register(error)
        }
    }

    func resendCode() async {
        do {
            try await AuthService.shared.registerCode(username: trimmedUsername, email: trimmedEmail)
            resendAt = Date().addingTimeInterval(AccountCode.resendSeconds)
            errorMessage = nil
        } catch {
            errorMessage = AuthErrorText.register(error)
        }
    }

    /// Back to the form, everything still filled in.
    func changeEmail() {
        stage = .details
        code = ""
        errorMessage = nil
    }
}

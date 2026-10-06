import Foundation
import Observation

/// Sign-up with username + password, with live per-field validation. On
/// success `AppState` moves the app into onboarding.
@MainActor
@Observable
final class RegisterViewModel {
    static let minUsername = 3
    static let minPassword = 8

    /// Lowercased as typed — the only silent normalization; anything else
    /// invalid is surfaced as a live hint so the user sees why.
    var username = "" {
        didSet { if username != username.lowercased() { username = username.lowercased() } }
    }
    var password = ""
    var confirmPassword = ""
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    // MARK: Live validation (nil = fine, or nothing typed yet)

    var usernameError: String? {
        guard !username.isEmpty else { return nil }
        if username.contains(where: { !($0.isLetter || $0.isNumber || $0 == "_") }) {
            return Bundle.app.loc("Only letters, numbers, and underscore (_) are allowed")
        }
        if username.count < Self.minUsername {
            return Bundle.app.loc("Username must be at least 3 characters")
        }
        return nil
    }

    var usernameHint: String {
        usernameError ?? Bundle.app.loc("Letters, numbers, and underscore (_) only, at least 3 characters")
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
        username.count >= Self.minUsername && usernameError == nil
            && password.count >= Self.minPassword
            && !confirmPassword.isEmpty && confirmPassword == password
    }

    // MARK: Submit

    func register(appState: AppState) async {
        let name = username.trimmingCharacters(in: .whitespaces)
        guard name.count >= Self.minUsername else {
            errorMessage = Bundle.app.loc("Username must be at least 3 characters"); return
        }
        guard password.count >= Self.minPassword else {
            errorMessage = Bundle.app.loc("Password must be at least 8 characters"); return
        }
        guard password == confirmPassword else {
            errorMessage = Bundle.app.loc("Passwords don't match"); return
        }
        isLoading = true
        errorMessage = nil
        do {
            // Success: AppState sets needsOnboarding and the root view moves on.
            try await appState.registerWithPassword(username: name, password: password)
        } catch {
            isLoading = false
            errorMessage = AuthErrorText.register(error)
        }
    }
}

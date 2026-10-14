import Foundation
import Observation

/// Sign-up with email + password, with live per-field validation. The
/// public @username is chosen next, in onboarding (with the email's code).
/// On success `AppState` moves the app into onboarding.
@MainActor
@Observable
final class RegisterViewModel {
    static let minPassword = 8

    var email = ""
    var password = ""
    var confirmPassword = ""
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    // MARK: Live validation (nil = fine, or nothing typed yet)

    private var trimmedEmail: String { email.trimmingCharacters(in: .whitespaces).lowercased() }

    /// Shaped like an address (the server checks it properly).
    static func looksLikeEmail(_ s: String) -> Bool {
        let parts = s.split(separator: "@", omittingEmptySubsequences: false)
        return parts.count == 2 && !parts[0].isEmpty && parts[1].contains(".") && !parts[1].hasSuffix(".") && !s.contains(" ")
    }

    var emailError: String? {
        guard !trimmedEmail.isEmpty else { return nil }
        return Self.looksLikeEmail(trimmedEmail) ? nil : Bundle.app.loc("Enter a valid email address")
    }

    var emailHint: String {
        emailError ?? Bundle.app.loc("You sign in with your email. You'll pick your public @username next.")
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
        Self.looksLikeEmail(trimmedEmail)
            && password.count >= Self.minPassword
            && !confirmPassword.isEmpty && confirmPassword == password
    }

    // MARK: Submit

    func register(appState: AppState) async {
        guard Self.looksLikeEmail(trimmedEmail) else {
            errorMessage = Bundle.app.loc("Enter a valid email address"); return
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
            try await appState.registerWithPassword(email: trimmedEmail, password: password)
        } catch {
            isLoading = false
            errorMessage = AuthErrorText.register(error)
        }
    }
}

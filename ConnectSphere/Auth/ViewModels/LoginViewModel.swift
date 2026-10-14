import Foundation
import Observation
import UIKit
import GoogleSignIn

/// Sign-in with username (or email) + password or Google, or by picking an
/// account that signed in on this device before. On success `AppState`
/// switches the root view, so this only reports failures.
@MainActor
@Observable
final class LoginViewModel {
    var username = ""
    var password = ""
    private(set) var savedAccounts: [SavedAccount] = SavedAccounts().all()
    private(set) var isLoading = false
    /// Shown in the form's error banner; nil = no banner.
    private(set) var errorMessage: String?

    func clearError() { errorMessage = nil }

    /// A saved account: fills its username (the password is still asked
    /// for), or signs in with Google for a Google-only account.
    func pick(_ account: SavedAccount, presenting rootViewController: UIViewController?, appState: AppState) async {
        errorMessage = nil
        if account.hasPassword {
            username = account.username
            password = ""
        } else {
            await loginWithGoogle(presenting: rootViewController, appState: appState)
        }
    }

    /// Removes it from this device's list (the account itself is untouched).
    func forget(_ account: SavedAccount) {
        SavedAccounts().forget(id: account.id)
        savedAccounts = SavedAccounts().all()
    }

    func loginWithPassword(appState: AppState) async {
        guard !username.isEmpty, !password.isEmpty else {
            errorMessage = Bundle.app.loc("Please fill in all fields.")
            return
        }
        isLoading = true
        errorMessage = nil
        do {
            try await appState.loginWithPassword(
                username: username.trimmingCharacters(in: .whitespaces),
                password: password)
            // Success: the root view switches away; keep the spinner until it does.
        } catch {
            isLoading = false
            errorMessage = AuthErrorText.login(error)
        }
    }

    /// Google's SDK needs a view controller to present its sheet from — the
    /// one UI piece the view supplies (nil if no window is available).
    func loginWithGoogle(presenting rootViewController: UIViewController?, appState: AppState) async {
        guard let rootViewController else {
            errorMessage = Bundle.app.loc("Couldn't sign in, please try again")
            return
        }
        isLoading = true
        errorMessage = nil
        do {
            let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: rootViewController)
            guard let idToken = result.user.idToken?.tokenString else {
                isLoading = false
                errorMessage = Bundle.app.loc("Could not get Google token")
                return
            }
            do {
                try await appState.loginWithGoogle(idToken: idToken)
            } catch {
                isLoading = false
                // The server's own reason (e.g. "Invalid Google token") is shown as-is;
                // only an unreachable server gets the localized network message.
                errorMessage = AuthErrorText.unreachable(error) ?? error.localizedDescription
            }
        } catch {
            isLoading = false
            if (error as NSError).code != GIDSignInError.canceled.rawValue {
                errorMessage = error.localizedDescription
            }
        }
    }
}

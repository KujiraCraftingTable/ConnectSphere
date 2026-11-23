import Foundation
import Observation
import UIKit
import GoogleSignIn

/// Sign-in with @username (or email) + password or Google, or by picking an
/// account that signed in on this device before. On success `AppState`
/// switches the root view, so this only reports failures.
@MainActor
@Observable
final class LoginViewModel {
    /// The age and Terms/Privacy box, the only one in the app: the two ways an
    /// account gets created, Sign up and Google (a Google account is created
    /// the moment Google confirms it), wait for it; Log in to an existing
    /// account doesn't. The tick is remembered on this phone for the current
    /// edition, and sign-up reads it from there.
    var acceptsPolicy = PolicyConsentMemory().acceptsCurrent {
        didSet { acceptsPolicy ? PolicyConsentMemory().remember() : PolicyConsentMemory().forget() }
    }
    /// The @username or the email.
    var identifier = ""
    var password = ""
    private(set) var savedAccounts: [SavedAccount] = SavedAccounts().all()
    private(set) var isLoading = false
    /// Shown in the form's error banner; nil = no banner.
    private(set) var errorMessage: String?
    /// Bumped when a saved password account is picked: the view moves the
    /// cursor to the password field.
    private(set) var passwordFocusRequest = 0

    func clearError() { errorMessage = nil }

    // MARK: Two-factor step

    /// Set while a sign-in waits for the code emailed to the account.
    private(set) var challenge: LoginChallenge?
    private(set) var resendAt: Date?
    var code = "" { didSet { if code != AccountCode.clean(code) { code = AccountCode.clean(code) } } }
    var canVerify: Bool { challenge != nil && code.count == 6 && !isLoading }

    private func handle(_ outcome: AppState.SignInOutcome) {
        if case .needsCode(let c) = outcome {
            challenge = c
            code = ""
            resendAt = Date().addingTimeInterval(AccountCode.resendSeconds)
            isLoading = false
        }
        // .signedIn: the root view switches away; keep the spinner until it does.
    }

    func verifyCode(appState: AppState) async {
        guard canVerify, let challenge else { return }
        isLoading = true
        errorMessage = nil
        do {
            try await appState.verifyLogin(challenge: challenge.challenge, code: code)
        } catch {
            isLoading = false
            errorMessage = AuthErrorText.unreachable(error) ?? error.localizedDescription
        }
    }

    func resendCode() async {
        guard let challenge else { return }
        do {
            self.challenge = try await AuthService.shared.resendLogin(challenge: challenge.challenge)
            resendAt = Date().addingTimeInterval(AccountCode.resendSeconds)
            errorMessage = nil
        } catch {
            errorMessage = AuthErrorText.unreachable(error) ?? error.localizedDescription
        }
    }

    /// Back to the username / password form.
    func cancelCode() {
        challenge = nil
        code = ""
        errorMessage = nil
    }

    /// A saved account goes straight to that account: a password account
    /// fills its username and waits for the password; a Google account opens
    /// Google on its own email, so only its password or passkey is asked for,
    /// not the list of every Google account on the phone.
    func pick(_ account: SavedAccount, presenting rootViewController: UIViewController?, appState: AppState) async {
        errorMessage = nil
        if account.hasPassword {
            identifier = account.username
            password = ""
            passwordFocusRequest += 1
        } else {
            await loginWithGoogle(presenting: rootViewController, appState: appState, hint: SavedAccounts().googleHint(for: account.id))
        }
    }

    /// Removes it from this device's list (the account itself is untouched).
    func forget(_ account: SavedAccount) {
        SavedAccounts().forget(id: account.id)
        savedAccounts = SavedAccounts().all()
    }

    func loginWithPassword(appState: AppState) async {
        guard !identifier.isEmpty, !password.isEmpty else {
            errorMessage = Bundle.app.loc("Please fill in all fields.")
            return
        }
        isLoading = true
        errorMessage = nil
        do {
            handle(try await appState.loginWithPassword(
                identifier: identifier.trimmingCharacters(in: .whitespaces).lowercased(),
                password: password))
        } catch {
            isLoading = false
            errorMessage = AuthErrorText.login(error)
        }
    }

    /// Google's SDK needs a view controller to present its sheet from. The
    /// one UI piece the view supplies (nil if no window is available).
    /// `hint` is the email to sign in as (a saved account); nil shows
    /// Google's account chooser.
    func loginWithGoogle(presenting rootViewController: UIViewController?, appState: AppState,
                         hint: String? = nil) async {
        guard acceptsPolicy else {
            errorMessage = Bundle.app.loc("Please tick to agree before continuing")
            return
        }
        guard let rootViewController else {
            errorMessage = Bundle.app.loc("Couldn't sign in, please try again")
            return
        }
        isLoading = true
        errorMessage = nil
        do {
            let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: rootViewController, hint: hint)
            guard let idToken = result.user.idToken?.tokenString else {
                isLoading = false
                errorMessage = Bundle.app.loc("Could not get Google token")
                return
            }
            do {
                handle(try await appState.loginWithGoogle(idToken: idToken))
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

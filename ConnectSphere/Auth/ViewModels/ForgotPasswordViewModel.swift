import Foundation
import Observation

/// Password reset in two steps: request a 6-digit code, then set a new
/// password with it.
@MainActor
@Observable
final class ForgotPasswordViewModel {
    enum Step { case requestCode, resetPassword, done }

    private(set) var step: Step = .requestCode
    var identifier = ""
    var otp = ""
    var newPassword = ""
    var confirmPassword = ""
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    private var trimmedIdentifier: String { identifier.trimmingCharacters(in: .whitespaces) }

    var canSendCode: Bool { !trimmedIdentifier.isEmpty && !isLoading }

    var passwordsMismatch: Bool { !confirmPassword.isEmpty && newPassword != confirmPassword }

    var canReset: Bool {
        otp.trimmingCharacters(in: .whitespaces).count == 6
            && newPassword.count >= 8
            && newPassword == confirmPassword
            && !isLoading
    }

    func sendCode() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            try await AuthService.shared.forgotPassword(identifier: trimmedIdentifier)
            step = .resetPassword
        } catch {
            errorMessage = Bundle.app.loc("Couldn't send code, please try again")
        }
    }

    func resetPassword() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            try await AuthService.shared.resetPassword(
                identifier: trimmedIdentifier,
                otp: otp.trimmingCharacters(in: .whitespaces),
                newPassword: newPassword)
            step = .done
        } catch {
            errorMessage = (error as NSError).code == 401
                ? Bundle.app.loc("Invalid or expired code")
                : Bundle.app.loc("Couldn't reset password, please try again")
        }
    }
}

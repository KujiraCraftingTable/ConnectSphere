import Foundation
import Observation

/// Changing the password, or setting one for the first time (Google account).
@MainActor
@Observable
final class ChangePasswordViewModel {
    static let minLength = 8

    var currentPassword = ""
    var newPassword = ""
    var confirmPassword = ""
    private(set) var isSaving = false
    private(set) var errorMessage: String?

    /// false = Google account with no password yet: no "current password" field.
    let hasPassword: Bool

    init(hasPassword: Bool) {
        self.hasPassword = hasPassword
    }

    var passwordsMismatch: Bool {
        !confirmPassword.isEmpty && newPassword != confirmPassword
    }

    var canSave: Bool {
        (!hasPassword || !currentPassword.isEmpty)
            && newPassword.count >= Self.minLength
            && newPassword == confirmPassword
            && !isSaving
    }

    /// Returns the new session token on success: the change ends every older
    /// session, this device's included. The caller keeps the token and marks the
    /// user as having a password (it may have just set its first one).
    func save(token: String?) async -> String? {
        guard let token else { return nil }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            return try await AuthService.shared.changePassword(
                token: token,
                currentPassword: hasPassword ? currentPassword : nil,
                newPassword: newPassword)
        } catch {
            errorMessage = (error as NSError).code == 401
                ? Bundle.app.loc("Current password is incorrect")
                : Bundle.app.loc("Couldn't change password, please try again")
            return nil
        }
    }
}

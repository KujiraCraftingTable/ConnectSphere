import Foundation
import Observation

/// Deleting (soft-deleting) the account, confirmed with the password — or by
/// typing "DELETE" for a Google account that never set one.
@MainActor
@Observable
final class DeleteAccountViewModel {
    var password = ""
    var confirmationText = ""
    private(set) var isDeleting = false
    private(set) var errorMessage: String?

    /// Whether the account can sign in with a password (decides which field is shown).
    let hasPassword: Bool

    private let repository = ProfileRepository()

    init(hasPassword: Bool) {
        self.hasPassword = hasPassword
    }

    var canDelete: Bool {
        !isDeleting && (hasPassword ? !password.isEmpty : confirmationText == "DELETE")
    }

    /// The account is disabled on success, so the token is no longer valid —
    /// the caller logs out back to sign-in.
    func deleteAccount() async -> Bool {
        isDeleting = true
        errorMessage = nil
        defer { isDeleting = false }
        do {
            try await repository.deleteAccount(
                password: hasPassword ? password : nil,
                confirmation: hasPassword ? nil : confirmationText)
            return true
        } catch {
            errorMessage = (error as NSError).code == 401
                ? Bundle.app.loc("Password is incorrect")
                : Bundle.app.loc("Couldn't delete account, please try again")
            return false
        }
    }
}

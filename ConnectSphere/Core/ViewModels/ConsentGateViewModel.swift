import Foundation
import Observation

/// Shown when the account hasn't agreed to the current Terms of Service and
/// Privacy Policy (they changed, or the account predates consent records).
@MainActor
@Observable
final class ConsentGateViewModel {
    var agrees = false
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    /// True once the server has the agreement recorded.
    func accept(token: String?) async -> Bool {
        guard agrees, let token else { return false }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            try await AuthService.shared.acceptConsent(token: token)
            return true
        } catch {
            errorMessage = friendlyError(error)
            return false
        }
    }
}

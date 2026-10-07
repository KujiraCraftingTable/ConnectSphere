import Foundation
import Observation

/// The "Allow friend requests" privacy switch. Off = strangers see Follow
/// instead of Add friend; the user can still send requests themselves.
@MainActor
@Observable
final class FriendRequestSettingViewModel {
    private(set) var isSaving = false
    var errorMessage: String?

    private let repository = ProfileRepository()

    /// Optimistic: the session user flips at once and is restored if saving fails.
    func set(_ allow: Bool, appState: AppState) async {
        let previous = appState.currentUser?.allowFriendRequests ?? true
        appState.currentUser?.allowFriendRequests = allow
        isSaving = true
        defer { isSaving = false }
        do {
            try await repository.setAllowFriendRequests(allow)
        } catch {
            appState.currentUser?.allowFriendRequests = previous
            errorMessage = Bundle.app.loc("Couldn't update this setting, please try again")
        }
    }
}

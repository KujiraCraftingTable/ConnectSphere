import Foundation
import Observation

/// "Lock my Hobby / Work profile", for the current mode.
@MainActor
@Observable
final class ProfileLockSettingViewModel {
    private(set) var isSaving = false
    var errorMessage: String?

    private let repository = ProfileRepository()

    /// Optimistic: the session user flips at once and is restored if saving fails.
    func set(_ locked: Bool, appState: AppState) async {
        let previous = appState.currentUser?.isLocked ?? false
        appState.currentUser?.isLocked = locked
        isSaving = true
        defer { isSaving = false }
        do {
            try await repository.setLocked(locked, mode: appState.currentMode)
        } catch {
            appState.currentUser?.isLocked = previous
            errorMessage = Bundle.app.loc("Couldn't update this setting, please try again")
        }
    }
}

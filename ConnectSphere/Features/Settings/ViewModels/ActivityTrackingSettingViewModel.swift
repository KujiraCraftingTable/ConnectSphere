import Foundation
import Observation

/// The "Personalise with my activity" privacy switch (the "do not track"
/// choice Law 91/2025 Art. 29.4 asks for). Turning it off also makes the
/// server delete the activity it had recorded.
@MainActor
@Observable
final class ActivityTrackingSettingViewModel {
    private(set) var isSaving = false
    var errorMessage: String?

    private let repository = ProfileRepository()

    /// Optimistic: the session user flips at once and is restored if saving fails.
    func set(_ track: Bool, appState: AppState) async {
        let previous = appState.currentUser?.trackActivity ?? true
        appState.currentUser?.trackActivity = track
        isSaving = true
        defer { isSaving = false }
        do {
            try await repository.setTrackActivity(track)
        } catch {
            appState.currentUser?.trackActivity = previous
            errorMessage = Bundle.app.loc("Couldn't update this setting, please try again")
        }
    }
}

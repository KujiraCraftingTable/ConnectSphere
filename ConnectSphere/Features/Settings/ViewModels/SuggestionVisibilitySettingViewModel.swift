import Foundation
import Observation

/// The "Show me in People you may know" privacy switch.
@MainActor
@Observable
final class SuggestionVisibilitySettingViewModel {
    private(set) var isSaving = false
    var errorMessage: String?

    private let repository = ProfileRepository()

    /// Optimistic: the session user flips at once and is restored if saving fails.
    func set(_ show: Bool, appState: AppState) async {
        let previous = appState.currentUser?.showInSuggestions ?? true
        appState.currentUser?.showInSuggestions = show
        isSaving = true
        defer { isSaving = false }
        do {
            try await repository.setShowInSuggestions(show)
        } catch {
            appState.currentUser?.showInSuggestions = previous
            errorMessage = Bundle.app.loc("Couldn't update this setting, please try again")
        }
    }
}

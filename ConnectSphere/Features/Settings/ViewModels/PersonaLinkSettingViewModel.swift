import Foundation
import Observation

/// The "Show a link to my Work / Hobby profile" switch, for the current mode.
@MainActor
@Observable
final class PersonaLinkSettingViewModel {
    private(set) var isSaving = false
    var errorMessage: String?

    private let repository = ProfileRepository()

    /// Optimistic: the session user flips at once and is restored if saving fails.
    func set(_ link: Bool, appState: AppState) async {
        let previous = appState.currentUser?.linksOtherMode ?? true
        appState.currentUser?.linksOtherMode = link
        isSaving = true
        defer { isSaving = false }
        do {
            try await repository.setLinksOtherMode(link, mode: appState.currentMode)
        } catch {
            appState.currentUser?.linksOtherMode = previous
            errorMessage = Bundle.app.loc("Couldn't update this setting, please try again")
        }
    }
}

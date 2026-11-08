import Foundation
import Observation

/// Picks a mode's colour palette and saves it to the account, so it follows
/// the person to any device and doesn't leak to other accounts on this one.
@MainActor
@Observable
final class ThemePickerViewModel {
    var errorMessage: String?

    private let repository = ProfileRepository()

    /// Optimistic: the colour changes at once and goes back if saving fails.
    func select(_ paletteId: String, mode: AppMode, themeManager: ThemeManager) async {
        let previous = themeManager.paletteId(for: mode)
        guard paletteId != previous else { return }
        themeManager.selectPalette(id: paletteId, for: mode)
        do {
            try await repository.setTheme(paletteId, mode: mode)
        } catch {
            #if DEBUG
            print("ThemePickerViewModel: saving theme failed: \(error)")
            #endif
            themeManager.selectPalette(id: previous, for: mode)
            errorMessage = Bundle.app.loc("Couldn't update this setting, please try again")
        }
    }
}

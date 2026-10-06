import Foundation
import Observation

/// First-run profile setup: four steps (mode → basics → interests/skills →
/// bio), then `AppState.completeOnboarding`.
@MainActor
@Observable
final class OnboardingViewModel {
    static let totalSteps = 4

    private(set) var step = 0
    var form = OnboardingForm()
    var selectedInterests: [InterestItem] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    /// Username was chosen and validated at registration — carry it forward
    /// instead of asking again, so the final setup call can't blank it.
    func prefill(username: String?) {
        if form.username.isEmpty { form.username = username ?? "" }
    }

    /// Step 2's required fields. Navigation is Next/Back only (no swiping), so
    /// an incomplete form can't be submitted.
    var basicsComplete: Bool {
        !form.display_name.trimmingCharacters(in: .whitespaces).isEmpty
            && !form.username.isEmpty
            && !form.location.isEmpty
            && !form.gender.isEmpty
            && !form.dob.isEmpty
    }

    /// Skills edited as one comma-separated line.
    var skillsText: String {
        get { form.skills.joined(separator: ", ") }
        set {
            form.skills = newValue.components(separatedBy: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
    }

    func next() { step = min(step + 1, Self.totalSteps - 1) }

    func finish(appState: AppState) async {
        form.interests = selectedInterests.map { $0.displayText }
        isLoading = true
        errorMessage = nil
        do {
            try await appState.completeOnboarding(form: form)
        } catch {
            errorMessage = friendlyError(error)
        }
        isLoading = false
    }
}

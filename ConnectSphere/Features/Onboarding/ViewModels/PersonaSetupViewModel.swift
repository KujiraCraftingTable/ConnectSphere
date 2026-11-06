import Foundation
import Observation

/// Creating the Hobby or Work persona the first time the user switches to a
/// mode that isn't set up yet.
@MainActor
@Observable
final class PersonaSetupViewModel {
    let mode: AppMode
    var displayName = "" {
        didSet { if displayName.count > DisplayNameRules.maxLength { displayName = DisplayNameRules.capped(displayName) } }
    }
    var jobTitle = ""
    var company = ""
    /// Work skills, picked from the skill catalogue (SkillPickerView).
    var skills: [String] = []
    var selectedInterests: [InterestItem] = []
    private(set) var isSaving = false
    private(set) var errorMessage: String?

    private let repository = ProfileRepository()

    init(mode: AppMode) {
        self.mode = mode
    }

    var isValid: Bool { !trimmed(displayName).isEmpty }

    /// Anything entered, closing the form would lose it, so Cancel asks.
    var hasChanges: Bool {
        !trimmed(displayName).isEmpty || !trimmed(jobTitle).isEmpty || !trimmed(company).isEmpty
            || !skills.isEmpty || !selectedInterests.isEmpty
    }

    /// The created profile on success. The caller hands it to `AppState`.
    func save() async -> UserProfile? {
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        let body = ProfileRepository.PersonaCreate(
            mode: mode.rawValue,
            display_name: trimmed(displayName),
            job_title: mode == .work ? nonEmpty(jobTitle) : nil,
            company: mode == .work ? nonEmpty(company) : nil,
            skills: mode == .work && !skills.isEmpty ? skills : nil,
            interests: mode == .hobby && !selectedInterests.isEmpty ? selectedInterests.map { $0.displayText } : nil)
        do {
            return try await repository.createPersona(body)
        } catch {
            errorMessage = Bundle.app.loc("Couldn't save, please try again")
            return nil
        }
    }

    private func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespaces) }
    private func nonEmpty(_ s: String) -> String? { trimmed(s).isEmpty ? nil : trimmed(s) }
}

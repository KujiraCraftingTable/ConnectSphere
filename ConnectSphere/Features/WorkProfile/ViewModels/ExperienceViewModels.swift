import Foundation
import Observation

// MARK: - Experience list
/// Someone's work history on their profile.
@MainActor
@Observable
final class ExperienceListViewModel {
    private(set) var roles: [WorkExperience] = []
    private(set) var isLoading = false
    private(set) var loaded = false
    var errorMessage: String?

    private let repository = WorkProfileRepository()

    var groups: [WorkExperience.Group] { WorkExperience.grouped(roles) }

    func load(userId: String, token: String) async {
        isLoading = !loaded
        defer { isLoading = false }
        do {
            roles = try await repository.experiences(of: userId, token: token)
            loaded = true
        } catch {
            if !loaded { errorMessage = friendlyError(error) }
        }
    }

    func replace(_ updated: [WorkExperience]) { roles = updated }
}

// MARK: - Experience editor
/// Adding or editing one of your roles.
@MainActor
@Observable
final class ExperienceEditorViewModel {
    var title = ""
    var companyName = ""
    /// Set when the company was picked from its page; typing clears it.
    var companyId: String?
    var employmentType: WorkExperience.EmploymentKind = .fullTime
    var location = ""
    var locationType: WorkExperience.LocationKind?
    var start = WorkMonth.now
    var end = WorkMonth.now
    var isCurrent = true
    var description = ""
    /// Company pages matching what's typed.
    private(set) var suggestions: [Company] = []
    private(set) var isSaving = false
    var errorMessage: String?

    let editing: WorkExperience?
    private let repository = WorkProfileRepository()
    private let companies = CompanyRepository()
    private var searchTask: Task<Void, Never>?

    /// Every field as it was when the editor opened.
    private var openedSignature: [String] = []
    private var signature: [String] {
        [title, companyName, companyId ?? "", employmentType.rawValue, location, locationType?.rawValue ?? "",
         "\(start)", isCurrent ? "current" : "\(end)", description]
    }
    /// Has anything been changed since the editor opened? Cancel only asks then.
    var hasChanges: Bool { signature != openedSignature }

    init(editing: WorkExperience? = nil) {
        self.editing = editing
        defer { openedSignature = signature }
        guard let e = editing else { return }
        title = e.title
        companyName = e.companyName
        companyId = e.companyId
        employmentType = e.employmentType
        location = e.location ?? ""
        locationType = e.locationType
        start = WorkMonth(e.startMonth) ?? .now
        if let endMonth = e.endMonth.flatMap(WorkMonth.init) {
            end = endMonth
            isCurrent = false
        }
        description = e.description ?? ""
    }

    // MARK: - Validation
    enum Field: Hashable { case title, company }
    /// Fields the user has left; an empty one only gets its hint then, so a
    /// fresh form doesn't open in red.
    var touched: Set<Field> = []

    private func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

    // The same limits the server enforces (ExperiencesController.validate).

    var titleProblem: String? {
        let t = trimmed(title)
        if t.count > 100 { return String(format: Bundle.app.loc("Keep the title under %lld characters."), 100) }
        return t.isEmpty && touched.contains(.title) ? Bundle.app.loc("Add your title.") : nil
    }

    var companyProblem: String? {
        let c = trimmed(companyName)
        if c.count > 100 { return String(format: Bundle.app.loc("Keep the company name under %lld characters."), 100) }
        return c.isEmpty && touched.contains(.company) ? Bundle.app.loc("Add the company.") : nil
    }

    var locationProblem: String? {
        trimmed(location).count > 100 ? String(format: Bundle.app.loc("Keep the location under %lld characters."), 100) : nil
    }

    var dateProblem: String? {
        if start > .now { return Bundle.app.loc("The start can't be in the future.") }
        guard !isCurrent else { return nil }
        if end > .now { return Bundle.app.loc("The end can't be in the future.") }
        if end < start { return Bundle.app.loc("The end can't be before the start.") }
        return nil
    }

    var descriptionProblem: String? {
        trimmed(description).count > 2000 ? String(format: Bundle.app.loc("Keep it under %lld characters."), 2000) : nil
    }

    var canSave: Bool {
        !trimmed(title).isEmpty && !trimmed(companyName).isEmpty && !isSaving
            && [titleProblem, companyProblem, locationProblem, dateProblem, descriptionProblem].allSatisfy { $0 == nil }
    }

    // MARK: - Company search
    /// Typing a name unlinks any picked page and looks for matching pages.
    func companyTyped(_ text: String, token: String) {
        if let picked = suggestions.first(where: { $0.id == companyId }), picked.name == text { return }
        companyId = nil
        searchTask?.cancel()
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2 else { suggestions = []; return }
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            suggestions = (try? await companies.search(q, token: token)) ?? []
        }
    }

    func pick(_ company: Company) {
        companyId = company.id
        companyName = company.name
        suggestions = []
    }

    // MARK: - Save & remove
    /// The updated list, or nil (with `errorMessage`).
    func save(token: String) async -> [WorkExperience]? {
        isSaving = true
        defer { isSaving = false }
        let form = WorkProfileRepository.ExperienceForm(
            company_id: companyId, company_name: companyName, title: title,
            employment_type: employmentType.rawValue, location: location,
            location_type: locationType?.rawValue, start_month: start.key,
            end_month: isCurrent ? nil : end.key, description: description)
        do {
            if let editing { return try await repository.updateExperience(id: editing.id, form, token: token) }
            return try await repository.addExperience(form, token: token)
        } catch {
            errorMessage = friendlyError(error)
            return nil
        }
    }

    func remove(token: String) async -> [WorkExperience]? {
        guard let editing else { return nil }
        isSaving = true
        defer { isSaving = false }
        do { return try await repository.removeExperience(id: editing.id, token: token) }
        catch {
            errorMessage = friendlyError(error)
            return nil
        }
    }
}

// MARK: - Company people
/// A company page's People tab.
@MainActor
@Observable
final class CompanyPeopleViewModel {
    private(set) var people: [WorkProfileRepository.CompanyPerson] = []
    private(set) var loaded = false
    private let repository = WorkProfileRepository()

    func load(companyId: String, token: String) async {
        people = (try? await repository.people(at: companyId, token: token)) ?? []
        loaded = true
    }
}

// MARK: - Skills
/// The Skills section: most-endorsed first; endorse when it's a Work connection.
@MainActor
@Observable
final class SkillsViewModel {
    private(set) var skills: [ProfileSkill] = []
    private(set) var canEndorse = false
    private(set) var loaded = false
    var errorMessage: String?

    private let repository = WorkProfileRepository()

    func load(userId: String, token: String) async {
        do {
            let result = try await repository.skills(of: userId, token: token)
            skills = result.data
            canEndorse = result.canEndorse
            errorMessage = nil   // a failure from an earlier try is over
            loaded = true
        } catch {
            // The view going away cancels its load; that isn't a failure.
            if Task.isCancelled || error is CancellationError { return }
            if !loaded { errorMessage = friendlyError(error) }
            loaded = true
        }
    }

    /// Shown at once; put back if the server refuses.
    func toggleEndorse(_ skill: ProfileSkill, userId: String, token: String) async {
        guard let i = skills.firstIndex(where: { $0.id == skill.id }) else { return }
        let before = skills
        skills[i].endorsedByMe.toggle()
        skills[i].endorsementCount = max(0, skill.endorsementCount + (skills[i].endorsedByMe ? 1 : -1))
        do {
            let result = try await repository.setEndorsed(skills[i].endorsedByMe, skillId: skill.id, of: userId, token: token)
            skills = result.data
            canEndorse = result.canEndorse
        } catch {
            skills = before
            errorMessage = friendlyError(error)
        }
    }
}

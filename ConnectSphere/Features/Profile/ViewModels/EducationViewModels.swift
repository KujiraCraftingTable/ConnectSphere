import Foundation
import Observation

/// Someone's schools on their Hobby profile.
@MainActor
@Observable
final class EducationListViewModel {
    private(set) var schools: [Education] = []
    private(set) var loaded = false
    private let repository = EducationRepository()

    func load(userId: String, token: String) async {
        schools = (try? await repository.list(of: userId, token: token)) ?? schools
        loaded = true
    }

    func replace(_ updated: [Education]) { schools = updated }
}

/// Adding or editing one of your schools.
@MainActor
@Observable
final class EducationEditorViewModel {
    var schoolName = ""
    var schoolType: Education.SchoolType = .university
    var major = ""
    var startYear: Int?
    var endYear: Int?
    private(set) var isSaving = false
    var errorMessage: String?

    let editing: Education?
    private let repository = EducationRepository()

    init(editing: Education? = nil) {
        self.editing = editing
        guard let e = editing else { return }
        schoolName = e.schoolName
        schoolType = e.schoolType
        major = e.major ?? ""
        startYear = e.startYear
        endYear = e.endYear
    }

    /// Built-in schools matching what's typed (none once it matches one exactly).
    var suggestions: [String] {
        let typed = schoolName.trimmingCharacters(in: .whitespaces)
        guard typed.count >= 2, !SchoolCatalog.schools.contains(typed) else { return [] }
        return SchoolCatalog.search(typed)
    }

    var yearsProblem: String? {
        if let s = startYear, let e = endYear, e < s { return Bundle.app.loc("The end can't be before the start.") }
        return nil
    }

    var canSave: Bool {
        schoolName.trimmingCharacters(in: .whitespaces).count >= 2 && yearsProblem == nil && !isSaving
    }

    /// Years offered: a few ahead (an expected graduation) back to 1950.
    static func years(now: Date = Date()) -> [Int] {
        let y = Calendar.current.component(.year, from: now)
        return Array((1950...(y + 7)).reversed())
    }

    private var form: EducationRepository.Form {
        let m = major.trimmingCharacters(in: .whitespaces)
        return .init(school_name: schoolName.trimmingCharacters(in: .whitespaces), school_type: schoolType.rawValue,
                     major: m.isEmpty ? nil : m, start_year: startYear, end_year: endYear)
    }

    /// The updated list, or nil (with `errorMessage`).
    func save(token: String) async -> [Education]? {
        guard canSave else { return nil }
        isSaving = true
        defer { isSaving = false }
        do {
            if let editing { return try await repository.update(id: editing.id, form, token: token) }
            return try await repository.add(form, token: token)
        } catch {
            errorMessage = friendlyError(error)
            return nil
        }
    }

    func remove(token: String) async -> [Education]? {
        guard let editing else { return nil }
        isSaving = true
        defer { isSaving = false }
        do { return try await repository.remove(id: editing.id, token: token) }
        catch {
            errorMessage = friendlyError(error)
            return nil
        }
    }
}

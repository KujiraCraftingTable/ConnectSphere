import Foundation
import Observation

/// The Work skill picker's catalogue: curated skills by category, the most
/// held first, plus LinkedIn-style "Suggested for you" from the job title
/// being edited. Like Upwork's skill list, nothing is added freely; a missing
/// skill can be suggested for review.
@MainActor
@Observable
final class SkillCatalogViewModel {
    private(set) var categories: [SkillCategory] = []
    private(set) var suggested: [String] = []
    private(set) var loadError: String?
    /// One line after a suggestion ("Thanks, we'll review it").
    var suggestNotice: String?
    var query = ""

    private let repository = SkillRepository()
    private var suggestedFor: String?

    var canSuggest: Bool { repository.canSuggest }

    // MARK: - Loading
    /// Loads the catalogue once; a changed job title only refreshes the
    /// suggestions.
    func load(jobTitle: String) async {
        let title = jobTitle.trimmingCharacters(in: .whitespaces)
        guard categories.isEmpty || title != suggestedFor else { return }
        do {
            let catalog = try await repository.catalog(jobTitle: title)
            categories = catalog.categories
            suggested = catalog.suggested
            suggestedFor = title
            loadError = nil
        } catch {
            if categories.isEmpty { loadError = friendlyError(error) }
        }
    }

    /// Categories with the skills matching `query` (either language or any
    /// alias, accents ignored); empty categories drop out.
    var visibleCategories: [SkillCategory] {
        let q = InterestCatalogViewModel.fold(query.trimmingCharacters(in: .whitespaces))
        guard !q.isEmpty else { return categories }
        return categories.compactMap { c in
            let hits = c.entries.filter { e in
                ([e.nameEn, e.nameVi] + e.aliases).contains { InterestCatalogViewModel.fold($0).contains(q) }
            }
            return hits.isEmpty ? nil : SkillCategory(key: c.key, nameEn: c.nameEn, nameVi: c.nameVi, entries: hits)
        }
    }

    // MARK: - Names & suggestions
    /// The skill's name in the app's language; skills from before the
    /// catalogue keep their stored text.
    func displayName(_ name: String, vietnamese: Bool) -> String {
        guard vietnamese,
              let e = categories.lazy.flatMap(\.entries).first(where: { $0.nameEn.caseInsensitiveCompare(name) == .orderedSame })
        else { return name }
        return e.nameVi
    }

    func suggest(_ text: String) async {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        do {
            if let existing = try await repository.suggest(t) {
                suggestNotice = String(format: Bundle.app.loc("It's already here as \"%@\". Search for it above."), existing)
            } else {
                suggestNotice = Bundle.app.loc("Thanks, we'll review your suggestion.")
            }
        } catch {
            suggestNotice = friendlyError(error)
        }
    }
}

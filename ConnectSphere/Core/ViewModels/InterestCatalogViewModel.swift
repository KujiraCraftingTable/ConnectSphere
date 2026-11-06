import Foundation
import Observation

/// The interest picker's catalogue: curated entries by category, the most
/// picked first and the lifestyle section (smoking, drinking…) last. Like
/// Bumble's badges or Tinder's passions, nothing is added freely. A missing
/// entry can be suggested for review.
@MainActor
@Observable
final class InterestCatalogViewModel {
    private(set) var categories: [InterestCategory] = []
    private(set) var maxPicks = 10
    private(set) var loadError: String?
    private(set) var isChecking = false
    /// Under the "Category · specific" field when the item can't be found.
    var specificError: String?
    /// One line after a suggestion ("Thanks, we'll review it").
    var suggestNotice: String?
    var query = ""

    private let repository = InterestRepository()

    var canSuggest: Bool { repository.canSuggest }

    func load() async {
        guard categories.isEmpty else { return }
        do {
            let catalog = try await repository.catalog()
            categories = catalog.categories
            maxPicks = catalog.maxPicks
            loadError = nil
        } catch {
            loadError = friendlyError(error)
        }
    }

    /// Categories with the entries matching `query` (either language or any
    /// alias, accents ignored); empty categories drop out.
    var visibleCategories: [InterestCategory] {
        let q = Self.fold(query.trimmingCharacters(in: .whitespaces))
        guard !q.isEmpty else { return categories }
        return categories.compactMap { c in
            let hits = c.entries.filter { e in
                ([e.nameEn, e.nameVi] + e.aliases).contains { Self.fold($0).contains(q) }
            }
            return hits.isEmpty ? nil : InterestCategory(key: c.key, nameEn: c.nameEn, nameVi: c.nameVi,
                                                         section: c.section, entries: hits)
        }
    }

    func entry(named name: String) -> InterestEntry? {
        categories.lazy.flatMap(\.entries).first { $0.nameEn.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// The entry's name in the app's language; picks from before the
    /// catalogue keep their stored text.
    func displayName(_ name: String, vietnamese: Bool) -> String {
        guard let e = entry(named: name) else { return name }
        return vietnamese ? e.nameVi : e.nameEn
    }

    /// The pick to store ("Gaming · Roblox"), or nil with `specificError` set
    /// when the item names nothing real.
    func checkSpecific(base: String, text: String) async -> String? {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return base }
        isChecking = true
        defer { isChecking = false }
        do {
            specificError = nil
            return try await repository.checkSpecific(base: base, text: t)
        } catch {
            specificError = friendlyError(error)
            return nil
        }
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

    static func fold(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: "đ", with: "d")
            .folding(options: .diacriticInsensitive, locale: Locale(identifier: "en"))
    }
}

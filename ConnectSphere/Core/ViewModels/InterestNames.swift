import Foundation
import Observation

/// Interests are stored by their English name ("Movies", "Gaming · Roblox"), so
/// a Vietnamese reader would see English chips. The curated catalogue has the
/// Vietnamese name of every entry; this loads it once and translates a stored
/// pick on demand. Until it loads (or if it can't), the stored text shows.
@MainActor
@Observable
final class InterestNames {
    static let shared = InterestNames()

    private(set) var viByEnglish: [String: String] = [:]
    private var didLoad = false
    private let repository = InterestRepository()

    /// A failed load is not shown: the chips stay in English and the next
    /// screen that needs the names tries again.
    func loadIfNeeded() async {
        guard !didLoad, let catalog = try? await repository.catalog() else { return }
        viByEnglish = Self.table(from: catalog)
        didLoad = true
    }

    func displayName(_ stored: String, in bundle: Bundle) -> String {
        Self.display(stored, vietnamese: Self.isVietnamese(bundle), table: viByEnglish)
    }

    /// English name (accents and case folded) to Vietnamese, for entries and categories.
    static func table(from catalog: InterestCatalog) -> [String: String] {
        var table: [String: String] = [:]
        for category in catalog.categories {
            table[InterestCatalogViewModel.fold(category.nameEn)] = category.nameVi
            for entry in category.entries {
                table[InterestCatalogViewModel.fold(entry.nameEn)] = entry.nameVi
            }
        }
        return table
    }

    /// "Gaming · Roblox" becomes "Trò chơi · Roblox": only the category part is
    /// in the catalogue, the specific item is the person's own words.
    static func display(_ stored: String, vietnamese: Bool, table: [String: String]) -> String {
        guard vietnamese else { return stored }
        var parts = stored.components(separatedBy: " · ")
        if let translated = table[InterestCatalogViewModel.fold(parts[0])] { parts[0] = translated }
        return parts.joined(separator: " · ")
    }

    static func isVietnamese(_ bundle: Bundle) -> Bool {
        bundle.bundleURL.lastPathComponent == "vi.lproj"
    }
}

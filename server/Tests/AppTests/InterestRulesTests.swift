@testable import App
import XCTest

/// Interests come from the curated catalogue (migration 080), like Bumble's
/// badges or Tinder's passions. Nothing is added freely.
final class InterestRulesTests: XCTestCase {
    private let catalog = SearchConceptTests.catalog

    private func normalize(_ items: [String], existing: Set<String> = []) throws -> [String] {
        try InterestRules.normalize(items, entries: catalog, existing: existing).picks
    }

    func testPicksTakeTheCataloguesSpelling() throws {
        XCTAssertEqual(try normalize(["anime", "bóng đá", "Anime"]), ["Anime", "Football"])
    }

    func testOnlyCatalogueEntries() {
        XCTAssertThrowsError(try normalize(["Underwater basket weaving"])) {
            XCTAssertEqual($0 as? InterestRules.Problem, .notInCatalog("Underwater basket weaving"))
        }
    }

    func testAtMostTen() {
        let eleven = catalog.map(\.name_en)
        XCTAssertThrowsError(try normalize(eleven)) { XCTAssertEqual($0 as? InterestRules.Problem, .tooMany) }
    }

    func testSpecificItemsOnlyWhereTheCategoryTakesOne() throws {
        XCTAssertThrowsError(try normalize(["Football · Arsenal"])) {
            XCTAssertEqual($0 as? InterestRules.Problem, .noSpecific("Football"))
        }
        let checked = try InterestRules.normalize(["Gaming · roblox"], entries: catalog, existing: [])
        // Left for the caller to confirm against known entities.
        XCTAssertEqual(checked.specifics.map(\.specific), ["roblox"])
    }

    /// Picks from before the catalogue can still be saved unchanged.
    func testExistingPicksStay() throws {
        XCTAssertEqual(try normalize(["Gaming · ndbdnd"], existing: ["Gaming · ndbdnd"]), ["Gaming · ndbdnd"])
    }

    func testTypedTextNeedsALetterAndNoSwearing() {
        XCTAssertThrowsError(try InterestRules.cleanText("67")) { XCTAssertEqual($0 as? InterestRules.Problem, .badText) }
        XCTAssertThrowsError(try InterestRules.cleanText("x")) { XCTAssertEqual($0 as? InterestRules.Problem, .badText) }
        XCTAssertThrowsError(try InterestRules.cleanText("đụ má")) { XCTAssertEqual($0 as? InterestRules.Problem, .blocked) }
        XCTAssertThrowsError(try InterestRules.cleanText("ma túy đá")) { XCTAssertEqual($0 as? InterestRules.Problem, .blocked) }
        XCTAssertEqual(try InterestRules.cleanText("  Pickle   ball "), "Pickle ball")
    }

    /// Folded, "các" (a plural) and "lợn" (pig) would read as swear words.
    func testVietnameseWordsAreNotMistakenForSwearing() {
        XCTAssertFalse(InterestRules.isBlocked("chơi các game"))
        XCTAssertFalse(InterestRules.isBlocked("nuôi lợn"))
        XCTAssertFalse(InterestRules.isBlocked("Sussex cricket"))
    }

    func testPopularFirstAndLifestyleLast() {
        func cat(_ key: String, _ section: String, picks: Int) -> InterestsController.CatalogCategory {
            .init(key: key, name_en: key, name_vi: key, section: section,
                  entries: [SearchConceptTests.entry(key, [], picks: picks)])
        }
        let sorted = InterestsController.sortCategories([
            cat("lifestyle", "lifestyle", picks: 50), cat("quiet", "main", picks: 1), cat("busy", "main", picks: 9),
        ])
        XCTAssertEqual(sorted.map(\.key), ["busy", "quiet", "lifestyle"])
    }
}

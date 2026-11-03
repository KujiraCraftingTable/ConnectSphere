@testable import App
import Vapor
import XCTest

/// A profile's or job's skills: catalogue spelling, aliases folded into one,
/// old free-text skills still valid on their own profile, and the caps.
final class SkillRulesTests: XCTestCase {
    static func entry(_ name: String, _ aliases: [String], parent: String? = nil) -> SkillStore.Entry {
        SkillStore.Entry(id: name, name_en: name, name_vi: name, category: "x", parent_id: parent,
                         aliases: aliases, pick_count: 0)
    }

    /// A slice of migration 084.
    static let catalog: [SkillStore.Entry] = [
        entry("JavaScript", ["javascript", "js"]),
        entry("React", ["react", "reactjs", "react.js"], parent: "JavaScript"),
        entry("Swift", ["swift"]),
        entry("Recruiting", ["recruiting", "tuyển dụng", "recruiter"]),
    ]

    private func normalize(_ items: [String], existing: Set<String> = [], limit: Int = 30) throws -> [String] {
        try SkillRules.normalize(items, entries: Self.catalog, existing: existing, limit: limit)
    }

    func testAliasesBecomeTheCatalogueName() throws {
        XCTAssertEqual(try normalize([" reactjs ", "tuyển dụng", "SWIFT"]), ["React", "Recruiting", "Swift"])
    }

    func testTwoSpellingsOfOneSkillCountOnce() throws {
        XCTAssertEqual(try normalize(["React", "react.js", "", "js"]), ["React", "JavaScript"])
    }

    func testRefusesASkillOutsideTheCatalogue() {
        XCTAssertThrowsError(try normalize(["Underwater basket weaving"])) {
            XCTAssertEqual($0 as? SkillRules.Problem, .notInCatalog("Underwater basket weaving"))
        }
    }

    func testAnOldFreeTextSkillStaysValidOnItsProfile() throws {
        XCTAssertEqual(try normalize(["vibe code", "Swift"], existing: ["vibe code"]), ["vibe code", "Swift"])
    }

    func testRefusesTooMany() {
        XCTAssertThrowsError(try normalize(["React", "Swift", "Recruiting"], limit: 2)) {
            XCTAssertEqual($0 as? SkillRules.Problem, .tooMany(2))
        }
        XCTAssertNoThrow(try normalize(["React", "reactjs", "Swift"], limit: 2))
    }

    func testTheBasicCleanStillTrimsAndDedupes() throws {
        XCTAssertEqual(try EndorsementStore.cleanSkills([" Swift ", "swift", "", "C++"]), ["Swift", "C++"])
    }
}

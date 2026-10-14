@testable import App
import Vapor
import XCTest

/// A profile's skill list: trimmed, case-insensitive de-dupe, and the caps.
final class SkillRulesTests: XCTestCase {
    func testCleansAndKeepsFirstSpelling() throws {
        XCTAssertEqual(try EndorsementStore.cleanSkills([" Swift ", "swift", "", "C++", "SWIFT"]), ["Swift", "C++"])
    }

    func testRefusesALongSkill() {
        XCTAssertThrowsError(try EndorsementStore.cleanSkills([String(repeating: "x", count: 51)]))
        XCTAssertNoThrow(try EndorsementStore.cleanSkills([String(repeating: "x", count: 50)]))
    }

    func testRefusesTooMany() {
        XCTAssertThrowsError(try EndorsementStore.cleanSkills((1...31).map { "s\($0)" }))
        // Duplicates don't count towards the cap.
        XCTAssertNoThrow(try EndorsementStore.cleanSkills((1...30).map { "s\($0)" } + ["S1"]))
    }
}

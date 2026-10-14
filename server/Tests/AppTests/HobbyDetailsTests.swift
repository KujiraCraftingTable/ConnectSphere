@testable import App
import Vapor
import XCTest

/// Hobby profile details: education entries, languages, relationship.
final class HobbyDetailsTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-10-15T00:00:00Z")!

    private func body(_ name: String = "Đại học Bách khoa Hà Nội", type: String = "university",
                      major: String? = "Computer Science", start: Int? = 2020, end: Int? = 2024) -> EducationsController.Body {
        .init(school_name: name, school_type: type, major: major, start_year: start, end_year: end)
    }

    func testAValidSchool() throws {
        let f = try EducationsController.validate(body(" FPT University  ", major: "  "), now: now)
        XCTAssertEqual(f.schoolName, "FPT University")
        XCTAssertNil(f.major)                       // blank → none
    }

    func testRefusedSchools() {
        XCTAssertThrowsError(try EducationsController.validate(body("A"), now: now))              // too short
        XCTAssertThrowsError(try EducationsController.validate(body(type: "kindergarten"), now: now))
        XCTAssertThrowsError(try EducationsController.validate(body(start: 2024, end: 2020), now: now))
        XCTAssertThrowsError(try EducationsController.validate(body(start: 1900), now: now))
        XCTAssertThrowsError(try EducationsController.validate(body(end: 2034), now: now))      // > now + 7
        XCTAssertNoThrow(try EducationsController.validate(body(end: 2033), now: now))           // expected graduation
        XCTAssertNoThrow(try EducationsController.validate(body(start: nil, end: nil), now: now))
    }

    func testLanguages() throws {
        XCTAssertEqual(try UsersController.cleanLanguages([" English ", "english", "", "Tiếng Việt"]), ["English", "Tiếng Việt"])
        XCTAssertThrowsError(try UsersController.cleanLanguages((1...11).map { "L\($0)" }))
        XCTAssertThrowsError(try UsersController.cleanLanguages([String(repeating: "x", count: 41)]))
    }

    func testRelationshipAllowlist() {
        XCTAssertTrue(UsersController.relationshipStatuses.contains("complicated"))
        XCTAssertFalse(UsersController.relationshipStatuses.contains("situationship"))
    }
}

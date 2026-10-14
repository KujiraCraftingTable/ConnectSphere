@testable import App
import Vapor
import XCTest

final class ExperienceValidationTests: XCTestCase {
    private let now = ExperiencesController.month("2026-10")!

    private func body(title: String? = "iOS Engineer", company: String? = "Acme", type: String? = "full_time",
                      start: String? = "2023-04", end: String? = nil, locationType: String? = nil) -> ExperiencesController.Body {
        .init(company_id: nil, company_name: company, title: title, employment_type: type, location: nil,
              location_type: locationType, start_month: start, end_month: end, description: nil)
    }

    func testMonthParsing() {
        XCTAssertNotNil(ExperiencesController.month("2024-03"))
        XCTAssertNil(ExperiencesController.month("2024-13"))
        XCTAssertNil(ExperiencesController.month("2024-3"))
        XCTAssertNil(ExperiencesController.month("March 2024"))
    }

    func testACurrentRoleIsValid() throws {
        let f = try ExperiencesController.validate(body(title: "  iOS Engineer "), companyName: nil, now: now)
        XCTAssertEqual(f.title, "iOS Engineer")
        XCTAssertNil(f.end)
        XCTAssertNil(f.companyID)
    }

    func testALinkedPageNamesTheCompany() throws {
        var b = body(company: "typed name")
        b.company_id = "11111111-1111-1111-1111-111111111111"
        let f = try ExperiencesController.validate(b, companyName: "FPT Software", now: now)
        XCTAssertEqual(f.companyName, "FPT Software")
        XCTAssertEqual(f.companyID, "11111111-1111-1111-1111-111111111111")
    }

    func testRejectsBadRoles() {
        func rejects(_ b: ExperiencesController.Body, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertThrowsError(try ExperiencesController.validate(b, companyName: nil, now: now), file: file, line: line)
        }
        rejects(body(title: " "))
        rejects(body(company: nil))
        rejects(body(type: "volunteer"))
        rejects(body(start: "2027-01"))                    // future start
        rejects(body(start: "2024-05", end: "2024-01"))    // ends before it starts
        rejects(body(end: "2030-01"))                      // future end
        rejects(body(locationType: "moon"))
    }
}

@testable import App
import Vapor
import XCTest

final class CompanyValidationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)   // 2027

    private func body(_ name: String? = "FPT Software", website: String? = nil, size: String? = nil,
                      year: Int? = nil, logo: String? = nil, about: String? = nil) -> CompaniesController.Body {
        .init(name: name, logo_url: logo, cover_url: nil, about: about, industry: nil, size: size,
              website: website, headquarters: nil, founded_year: year)
    }

    func testAValidPageIsTrimmedAndTidied() throws {
        let f = try CompaniesController.validate(body("  FPT Software ", website: "fpt.com", size: "1000+",
                                                      year: 1999, about: "  "), now: now)
        XCTAssertEqual(f.name, "FPT Software")
        XCTAssertEqual(f.website, "https://fpt.com")   // a bare domain gets https://
        XCTAssertEqual(f.size, "1000+")
        XCTAssertNil(f.about)                          // blank becomes nil
    }

    func testRejectsBadPages() {
        func rejects(_ b: CompaniesController.Body, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertThrowsError(try CompaniesController.validate(b, now: now), file: file, line: line)
        }
        rejects(body(nil))
        rejects(body("A"))                                   // too short
        rejects(body(String(repeating: "x", count: 101)))    // too long
        rejects(body(website: "not a site"))
        rejects(body(size: "huge"))
        rejects(body(year: 1700))
        rejects(body(year: 2030))                            // in the future
        rejects(body(logo: "https://evil.example/logo.png")) // not our upload
        rejects(body(about: String(repeating: "x", count: 2001)))
    }
}

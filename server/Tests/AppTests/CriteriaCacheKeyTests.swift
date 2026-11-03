@testable import App
import XCTest

/// The same prompt in the same mode reuses its reading; another mode doesn't.
final class CriteriaCacheKeyTests: XCTestCase {
    func testSpacingAndCaseDoNotMatterButModeDoes() {
        let a = OllamaService.criteriaCacheKey("  Bạn  thích ĐÁ banh ", mode: "hobby")
        XCTAssertEqual(a, OllamaService.criteriaCacheKey("bạn thích đá banh", mode: "hobby"))
        XCTAssertNotEqual(a, OllamaService.criteriaCacheKey("bạn thích đá banh", mode: "work"))
        XCTAssertNotEqual(a, OllamaService.criteriaCacheKey("bạn thích đá banh", mode: nil))
    }
}

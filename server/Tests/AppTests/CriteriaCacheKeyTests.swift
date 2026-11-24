@testable import App
import XCTest

/// The same prompt in the same mode, read by the same model, reuses its
/// reading; another mode or another model doesn't.
final class CriteriaCacheKeyTests: XCTestCase {
    private let model = "qwen2.5:7b-instruct-q4_k_m"

    func testSpacingAndCaseDoNotMatterButModeDoes() {
        let a = OllamaService.criteriaCacheKey("  Bạn  thích ĐÁ banh ", mode: "hobby", model: model)
        XCTAssertEqual(a, OllamaService.criteriaCacheKey("bạn thích đá banh", mode: "hobby", model: model))
        XCTAssertNotEqual(a, OllamaService.criteriaCacheKey("bạn thích đá banh", mode: "work", model: model))
        XCTAssertNotEqual(a, OllamaService.criteriaCacheKey("bạn thích đá banh", mode: nil, model: model))
    }

    func testAnotherModelNeverReusesTheReading() {
        XCTAssertNotEqual(
            OllamaService.criteriaCacheKey("chess players in District 1", mode: "hobby", model: model),
            OllamaService.criteriaCacheKey("chess players in District 1", mode: "hobby", model: "qwen2.5:3b-instruct-q4_k_m"))
    }
}

import XCTest
@testable import App

final class MarkdownTextTests: XCTestCase {
    func testInlineSymbolsAreRemoved() {
        XCTAssertEqual(MarkdownText.plain("**bold** and _italic_ and ~~gone~~ and `code`"), "bold and italic and gone and code")
    }

    func testLinksKeepOnlyTheirLabel() {
        XCTAssertEqual(MarkdownText.plain("see [the docs](https://example.com/a?b=1) now"), "see the docs now")
    }

    func testListAndQuoteMarkersGoButTheWordsStay() {
        XCTAssertEqual(MarkdownText.plain("- one\n- two\n1. three\n> four"), "one\ntwo\nthree\nfour")
    }

    func testSnakeCaseAndMathAreLeftAlone() {
        XCTAssertEqual(MarkdownText.plain("use user_name and 2 * 3"), "use user_name and 2 * 3")
    }

    func testPlainTextPassesThrough() {
        XCTAssertEqual(MarkdownText.plain("Xin chào, mình tên là Minh!"), "Xin chào, mình tên là Minh!")
    }

    func testOnlyKnownFormatsAreAccepted() {
        XCTAssertEqual(PostStore.contentFormats, ["plain", "markdown"])
    }
}

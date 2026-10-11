import XCTest
@testable import App

final class MutedWordValidationTests: XCTestCase {
    func testWordsAreTrimmedCollapsedAndHashStripped() {
        XCTAssertEqual(MutedWordStore.cleanWord("  spoiler  "), "spoiler")
        XCTAssertEqual(MutedWordStore.cleanWord("#Chết"), "Chết")
        XCTAssertEqual(MutedWordStore.cleanWord("##game   of\n thrones"), "game of thrones")
        XCTAssertNil(MutedWordStore.cleanWord("   "))
        XCTAssertNil(MutedWordStore.cleanWord(nil))
        XCTAssertNil(MutedWordStore.cleanWord("#"))
    }

    func testWordsNeedALetterOrDigitAndAtMostFiftyCharacters() {
        XCTAssertNil(MutedWordStore.cleanWord("!!!"))          // folds to nothing: could never match
        XCTAssertEqual(MutedWordStore.cleanWord("18+"), "18+")
        XCTAssertNil(MutedWordStore.cleanWord(String(repeating: "a", count: 51)))
        XCTAssertEqual(MutedWordStore.cleanWord(String(repeating: "đ", count: 50))?.count, 50)
    }

    func testOnlyKnownDurationsAndModes() throws {
        XCTAssertEqual(MutedWordStore.durations.keys.sorted(), ["24h", "30d", "7d", "forever"])
        XCTAssertEqual(MutedWordStore.durations["7d"], .some(604_800))
        XCTAssertEqual(MutedWordStore.durations["forever"], .some(nil))
        XCTAssertNil(MutedWordStore.durations["1y"])
        XCTAssertEqual(try MutedWordsController.validMode("work"), "work")
        XCTAssertThrowsError(try MutedWordsController.validMode("friend"))
        XCTAssertThrowsError(try MutedWordsController.validMode(nil))
    }
}

import XCTest
@testable import App

final class AltTextTests: XCTestCase {
    func testAltsLineUpWithTheMedia() {
        XCTAssertEqual(PostStore.cleanAlts(["  a dog  ", "", "a cat"], count: 3), ["a dog", "", "a cat"])
        XCTAssertEqual(PostStore.cleanAlts(["only first"], count: 3), ["only first", "", ""])       // padded
        XCTAssertEqual(PostStore.cleanAlts(["a", "b", "c"], count: 2), ["a", "b"])                 // never longer
    }

    func testNothingWrittenOrNoMediaStoresNothing() {
        XCTAssertNil(PostStore.cleanAlts(["", "   "], count: 2))
        XCTAssertNil(PostStore.cleanAlts(["a dog"], count: 0))
        XCTAssertNil(PostStore.cleanAlts(nil, count: 2))
    }

    func testEachAltIsCapped() {
        let long = String(repeating: "ả", count: 400)
        XCTAssertEqual(PostStore.cleanAlts([long], count: 1)?.first?.count, PostStore.maxAltLength)
    }
}

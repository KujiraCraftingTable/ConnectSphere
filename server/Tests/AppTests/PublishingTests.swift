import XCTest
@testable import App

final class PublishingTests: XCTestCase {
    func testPublishChoices() throws {
        let now = try Publishing.from(nil)
        XCTAssertEqual(now.status, "posted"); XCTAssertTrue(now.isLive); XCTAssertNotNil(now.datesAfter)
        let draft = try Publishing.from("draft")
        XCTAssertEqual(draft.status, "draft"); XCTAssertFalse(draft.isLive)
        XCTAssertNil(draft.datesAfter)   // a draft's dates are checked when it's published
        XCTAssertThrowsError(try Publishing.from("later"))
    }
}

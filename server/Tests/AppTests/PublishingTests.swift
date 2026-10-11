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

final class SchedulingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testScheduleWindowIsFiveMinutesToSixMonths() {
        XCTAssertFalse(PostPublisher.validScheduleTime(now.addingTimeInterval(4 * 60), now: now))
        XCTAssertTrue(PostPublisher.validScheduleTime(now.addingTimeInterval(5 * 60), now: now))
        XCTAssertTrue(PostPublisher.validScheduleTime(now.addingTimeInterval(180 * 86_400), now: now))
        XCTAssertFalse(PostPublisher.validScheduleTime(now.addingTimeInterval(181 * 86_400), now: now))
        XCTAssertFalse(PostPublisher.validScheduleTime(now.addingTimeInterval(-60), now: now))
    }

    func testScheduledPostsCheckTheirDatesAgainstThePublishTime() throws {
        let iso = ISO8601DateFormatter()
        let at = now.addingTimeInterval(3600)
        let p = try Publishing.from("schedule", at: iso.string(from: at), now: now)
        XCTAssertEqual(p.status, "scheduled")
        XCTAssertEqual(p.publishAt, at)
        XCTAssertEqual(p.datesAfter, at)      // a poll must end after the post goes out, not after now
        XCTAssertFalse(p.isLive)
        XCTAssertThrowsError(try Publishing.from("schedule", at: nil, now: now))
        XCTAssertThrowsError(try Publishing.from("schedule", at: "tomorrow", now: now))
        XCTAssertThrowsError(try Publishing.from("schedule", at: iso.string(from: now.addingTimeInterval(60)), now: now))
    }
}

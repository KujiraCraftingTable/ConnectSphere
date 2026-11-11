@testable import App
import XCTest

/// Per-account limits (spam is sent in bulk, mostly by new accounts).
final class UserRateLimiterTests: XCTestCase {
    func testNewAccountsGetAQuarterOfTheRoom() {
        XCTAssertEqual(UserRateLimiter.rule(.comment, isNewAccount: false).max, 60)
        XCTAssertEqual(UserRateLimiter.rule(.comment, isNewAccount: true).max, 15)
        XCTAssertEqual(UserRateLimiter.rule(.newChat, isNewAccount: true).max, 5)
        XCTAssertEqual(UserRateLimiter.rule(.friendRequest, isNewAccount: true).window, 86_400)
    }

    func testAccountIsNewForFortyEightHours() {
        let now = Date()
        XCTAssertTrue(UserRateLimiter.isNewAccount(createdAt: now.addingTimeInterval(-47 * 3600), now: now))
        XCTAssertFalse(UserRateLimiter.isNewAccount(createdAt: now.addingTimeInterval(-49 * 3600), now: now))
    }

    func testTheLimitStopsTheNextUseNotTheLast() throws {
        let limiter = UserRateLimiter()
        for _ in 0..<5 {
            try limiter.check(.newChat, user: "u1", isNewAccount: true)
            limiter.record(.newChat, user: "u1", isNewAccount: true)
        }
        XCTAssertThrowsError(try limiter.check(.newChat, user: "u1", isNewAccount: true)) {
            XCTAssertEqual(($0 as? InlineError)?.status, .tooManyRequests)
        }
    }

    func testOnlyRecordedUsesCount() throws {
        let limiter = UserRateLimiter()
        // Checked but never recorded: rejected attempts don't use up the room.
        for _ in 0..<20 { try limiter.check(.newChat, user: "u1", isNewAccount: true) }
        XCTAssertNoThrow(try limiter.check(.newChat, user: "u1", isNewAccount: true))
    }

    func testEachAccountAndActionCountsApart() throws {
        let limiter = UserRateLimiter()
        for _ in 0..<5 { limiter.record(.newChat, user: "a", isNewAccount: true) }
        XCTAssertNoThrow(try limiter.check(.newChat, user: "b", isNewAccount: true))
        XCTAssertNoThrow(try limiter.check(.comment, user: "a", isNewAccount: true))
    }
}

@testable import App
import XCTest

/// Per-account limits (spam is sent in bulk, mostly by new accounts).
final class UserRateLimiterTests: XCTestCase {
    func testNewAccountsGetAQuarterOfTheRoom() {
        XCTAssertEqual(UserRateLimiter.rule(.post, isNewAccount: false).max, 20)
        XCTAssertEqual(UserRateLimiter.rule(.post, isNewAccount: true).max, 5)
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
        for _ in 0..<5 { try limiter.spend(.post, user: "u1", isNewAccount: true) }
        XCTAssertThrowsError(try limiter.spend(.post, user: "u1", isNewAccount: true)) {
            XCTAssertEqual(($0 as? InlineError)?.status, .tooManyRequests)
        }
    }

    func testEachAccountAndActionCountsApart() throws {
        let limiter = UserRateLimiter()
        for _ in 0..<5 { try limiter.spend(.post, user: "a", isNewAccount: true) }
        XCTAssertNoThrow(try limiter.spend(.post, user: "b", isNewAccount: true))
        XCTAssertNoThrow(try limiter.spend(.comment, user: "a", isNewAccount: true))
    }
}

@testable import App
import XCTest

/// A @username can change once every six months (migration 141).
final class UsernameRulesTests: XCTestCase {
    private func at(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

    func testNeverChangedCanChangeNow() {
        XCTAssertTrue(UsernameRules.canChange(lastChangedAt: nil, now: at("2026-11-13T10:00:00Z")))
        XCTAssertNil(UsernameRules.nextChange(after: nil))
    }

    func testBlockedForSixMonthsAfterAChange() {
        let changed = at("2026-11-13T10:00:00Z")
        XCTAssertFalse(UsernameRules.canChange(lastChangedAt: changed, now: at("2026-11-14T10:00:00Z")))
        XCTAssertFalse(UsernameRules.canChange(lastChangedAt: changed, now: at("2027-05-12T10:00:00Z")))
        XCTAssertFalse(UsernameRules.canChange(lastChangedAt: changed, now: at("2027-05-13T09:59:59Z")))
    }

    func testAllowedAgainSixCalendarMonthsLater() {
        let changed = at("2026-11-13T10:00:00Z")
        XCTAssertEqual(UsernameRules.nextChange(after: changed), at("2027-05-13T10:00:00Z"))
        XCTAssertTrue(UsernameRules.canChange(lastChangedAt: changed, now: at("2027-05-13T10:00:00Z")))
        XCTAssertTrue(UsernameRules.canChange(lastChangedAt: changed, now: at("2028-01-01T00:00:00Z")))
    }

    func testEndOfMonthClampsLikePostgres() {
        // 31 August + 6 months: no 31 February, so the last day of February.
        XCTAssertEqual(UsernameRules.nextChange(after: at("2026-08-31T12:00:00Z")), at("2027-02-28T12:00:00Z"))
        XCTAssertEqual(UsernameRules.nextChange(after: at("2027-08-31T12:00:00Z")), at("2028-02-29T12:00:00Z"))
    }

    func testCooldownReasonNamesTheDay() {
        XCTAssertEqual(UsernameRules.cooldownReason(until: at("2027-05-13T10:00:00Z")),
                       "You can change your username again on 13 May 2027.")
    }

    func testNormalizedLikeSignIn() {
        XCTAssertEqual(UsernameRules.normalized("  @Minh_Tri "), "minh_tri")
        XCTAssertEqual(UsernameRules.normalized(nil), "")
    }

    func testSameFormatAsSignUp() {
        XCTAssertTrue(UsernameRules.isValidFormat("abc"))
        XCTAssertTrue(UsernameRules.isValidFormat(String(repeating: "a", count: 30)))
        XCTAssertTrue(UsernameRules.isValidFormat("tri_2026"))
        XCTAssertFalse(UsernameRules.isValidFormat("ab"))
        XCTAssertFalse(UsernameRules.isValidFormat(String(repeating: "a", count: 31)))
        XCTAssertFalse(UsernameRules.isValidFormat("tri.minh"))
        XCTAssertFalse(UsernameRules.isValidFormat("Tri"))
        XCTAssertFalse(UsernameRules.isValidFormat("tri minh"))
    }
}

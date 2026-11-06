@testable import App
import XCTest

/// A birthday decides what an account may use, so it can change only twice.
final class BirthdayRulesTests: XCTestCase {
    func testTwoChangesForTheWholeAccount() {
        XCTAssertEqual(BirthdayRules.changesLeft(used: 0), 2)
        XCTAssertEqual(BirthdayRules.changesLeft(used: 1), 1)
        XCTAssertEqual(BirthdayRules.changesLeft(used: 2), 0)
        XCTAssertEqual(BirthdayRules.changesLeft(used: 5), 0)
    }

    func testSavingTheSameBirthdayIsNotAChange() {
        XCTAssertFalse(BirthdayRules.isChange(from: "2005-03-01", to: "2005-03-01"))
        XCTAssertFalse(BirthdayRules.isChange(from: "2005-03-01", to: "2005-03-01T00:00:00Z"))
        XCTAssertFalse(BirthdayRules.isChange(from: nil, to: nil))
        XCTAssertFalse(BirthdayRules.isChange(from: nil, to: ""))
    }

    func testAnyDifferenceCountsIncludingSettingOrClearing() {
        XCTAssertTrue(BirthdayRules.isChange(from: "2005-03-01", to: "2004-03-01"))
        XCTAssertTrue(BirthdayRules.isChange(from: nil, to: "2005-03-01"))
        XCTAssertTrue(BirthdayRules.isChange(from: "2005-03-01", to: nil))
    }

    func testSixteenIsTheMinimumAge() {
        let today = JSONCoding.dateOnly.date(from: "2026-11-05")!
        XCTAssertTrue(BirthdayRules.isOldEnough("2010-11-05", today: today))   // turns 16 today
        XCTAssertFalse(BirthdayRules.isOldEnough("2010-11-06", today: today))  // 16 tomorrow
        XCTAssertTrue(BirthdayRules.isOldEnough("2005-03-01T00:00:00Z", today: today))
        XCTAssertFalse(BirthdayRules.isOldEnough("not a date", today: today))
        XCTAssertFalse(BirthdayRules.isOldEnough("", today: today))
    }
}

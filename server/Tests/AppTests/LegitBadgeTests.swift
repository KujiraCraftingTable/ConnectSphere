@testable import App
import XCTest

/// The Legit badge: a high average over enough reviews (migration 133).
final class LegitBadgeTests: XCTestCase {
    func testNeedsEnoughReviews() {
        XCTAssertFalse(LegitStore.isLegit(average: 5.0, count: LegitStore.badgeMinReviews - 1))
        XCTAssertTrue(LegitStore.isLegit(average: 5.0, count: LegitStore.badgeMinReviews))
    }

    func testNeedsHighAverage() {
        XCTAssertTrue(LegitStore.isLegit(average: 4.6, count: 80))
        XCTAssertFalse(LegitStore.isLegit(average: 4.5, count: 80))
    }

    func testNoReviewsIsNotLegit() {
        XCTAssertFalse(LegitStore.isLegit(average: nil, count: 0))
    }

    func testThresholds() {
        XCTAssertEqual(LegitStore.badgeMinAverage, 4.6)
        XCTAssertEqual(LegitStore.badgeMinReviews, 50)
    }
}

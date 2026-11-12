@testable import App
import XCTest

/// Marketplace seller profile and seller follows (migration 135).
final class SellerProfileTests: XCTestCase {
    /// `pushUserNotification` drops unregistered types, so without this no
    /// follower would ever hear about a new listing.
    func testSellerListedIsRegistered() {
        XCTAssertEqual(NotificationsController.types["seller_listed"]?.destination, "post")
        XCTAssertEqual(NotifyService.defaultEntityType("seller_listed"), "post")
    }

    func testAuthorExprOnlySwapsListingsAndLegit() {
        let sql = SellerProfileStore.authorExpr("display_name", post: "p", fallback: "u.display_name")
        XCTAssertTrue(sql.contains("p.post_type IN ('listing', 'legit')"))
        XCTAssertTrue(sql.hasSuffix(", u.display_name)"), "falls back to the persona when nothing is set")
    }

    func testLimits() {
        XCTAssertEqual(SellerProfileStore.maxNameLength, 50)
        XCTAssertEqual(SellerProfileStore.maxBioLength, 300)
    }
}

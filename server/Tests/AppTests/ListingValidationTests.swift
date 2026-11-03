@testable import App
import Vapor
import XCTest

final class ListingValidationTests: XCTestCase {
    private typealias In = PostsController.CreateBody.ListingDataIn

    private func input(title: String? = "Road bike", price: Int64? = 2_500_000, condition: String? = "good",
                       location: String? = nil, autoReply: String? = nil, hide: Bool? = nil) -> In {
        In(title: title, price: price, condition: condition, location: location, autoReply: autoReply, hideFromFriends: hide)
    }

    func testValidListingIsTrimmedAndDefaulted() throws {
        let d = try ListingStore.validate(input(title: "  Road bike  ", location: "  ", autoReply: " Yes, still here! "))
        XCTAssertEqual(d.title, "Road bike")
        XCTAssertNil(d.location, "a blank location is no location")
        XCTAssertEqual(d.autoReply, "Yes, still here!")
        XCTAssertFalse(d.hideFromFriends)
    }

    func testFreeIsAllowed() throws {
        XCTAssertEqual(try ListingStore.validate(input(price: 0)).price, 0)
    }

    func testMissingDetailsAreRejected() {
        XCTAssertThrowsError(try ListingStore.validate(nil))
        XCTAssertThrowsError(try ListingStore.validate(input(title: "   ")))
        XCTAssertThrowsError(try ListingStore.validate(input(price: nil)))
        XCTAssertThrowsError(try ListingStore.validate(input(condition: nil)))
    }

    func testCommunitiesAreOptionalDedupedAndCappedAtFive() throws {
        XCTAssertEqual(try ListingStore.communityIDs(nil), [])
        let a = UUID().uuidString, b = UUID().uuidString
        XCTAssertEqual(try ListingStore.communityIDs([a, b, a.lowercased()]), [a.lowercased(), b.lowercased()])
        let five = (0..<5).map { _ in UUID().uuidString }
        XCTAssertEqual(try ListingStore.communityIDs(five).count, 5)
        XCTAssertThrowsError(try ListingStore.communityIDs(five + [UUID().uuidString]))
        XCTAssertThrowsError(try ListingStore.communityIDs(["not-a-uuid"]))
    }

    func testMapLocationNeedsBothCoordinatesInRange() throws {
        XCTAssertNil(try ListingStore.coordinates(nil, nil))
        let point = try ListingStore.coordinates(10.7725, 106.698)
        XCTAssertEqual(point?.0, 10.7725)
        XCTAssertEqual(point?.1, 106.698)
        XCTAssertThrowsError(try ListingStore.coordinates(10.7725, nil))
        XCTAssertThrowsError(try ListingStore.coordinates(nil, 106.698))
        XCTAssertThrowsError(try ListingStore.coordinates(91, 0))
        XCTAssertThrowsError(try ListingStore.coordinates(0, -181))
    }

    func testValuesOutsideTheRulesAreRejected() {
        XCTAssertThrowsError(try ListingStore.validate(input(price: -1)))
        XCTAssertThrowsError(try ListingStore.validate(input(price: ListingStore.maxPrice + 1)))
        XCTAssertThrowsError(try ListingStore.validate(input(condition: "broken")))
        XCTAssertThrowsError(try ListingStore.validate(input(title: String(repeating: "a", count: 101))))
        XCTAssertThrowsError(try ListingStore.validate(input(autoReply: String(repeating: "a", count: 501))))
    }
}

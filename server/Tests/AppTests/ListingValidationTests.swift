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

    func testPhotoEditsNeedAtLeastOnePhoto() throws {
        var patch = ListingStore.Patch()
        XCTAssertNil(try ListingStore.photoUpdate(patch), "a patch without photos leaves them alone")
        patch.image_urls = []
        XCTAssertThrowsError(try ListingStore.photoUpdate(patch))
        patch.image_urls = ["/uploads/a.jpg", "/uploads/b.jpg"]
        patch.image_alts = ["front"]
        let update = try ListingStore.photoUpdate(patch)
        XCTAssertEqual(update?.urls.count, 2)
        XCTAssertEqual(update?.alts?.count, 2, "alts line up with the photos")
    }

    // MARK: auto re-up (migration 095)

    private func date(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

    func testNextAutoReupIsCountedInVietnamTime() {
        // Thu 5 Nov 2026 10:30 in Vietnam (03:30 UTC).
        let now = date("2026-11-05T10:30:00+07:00")
        XCTAssertEqual(ListingStore.nextAutoReup(from: now, days: 1, hour: 9), date("2026-11-06T09:00:00+07:00"))
        XCTAssertEqual(ListingStore.nextAutoReup(from: now, days: 3, hour: 18), date("2026-11-08T18:00:00+07:00"))
        XCTAssertEqual(ListingStore.nextAutoReup(from: now, days: 7, hour: 21), date("2026-11-12T21:00:00+07:00"))
        // 24 is midnight at the end of that day.
        XCTAssertEqual(ListingStore.nextAutoReup(from: now, days: 1, hour: 24), date("2026-11-07T00:00:00+07:00"))
        // Just after midnight in Vietnam is still "today" there, whatever the UTC date.
        let late = date("2026-11-05T23:50:00+07:00")
        XCTAssertEqual(ListingStore.nextAutoReup(from: late, days: 1, hour: 9), date("2026-11-06T09:00:00+07:00"))
    }

    func testAMissedSlotNeverFiresTwice() {
        let slot = date("2026-11-05T09:00:00+07:00")
        let now = date("2026-11-12T10:00:00+07:00")   // the server was down for a week
        XCTAssertEqual(ListingStore.advanceAutoReup(slot, days: 3, after: now), date("2026-11-14T09:00:00+07:00"))
        XCTAssertGreaterThan(ListingStore.advanceAutoReup(slot, days: 1, after: now), now)
    }

    func testAutoReupOnlyTakesTheAllowedChoices() throws {
        XCTAssertNoThrow(try ListingStore.validateAutoReup(nil))
        XCTAssertNoThrow(try ListingStore.validateAutoReup(.init(every_days: 3, hour: 24)))
        XCTAssertThrowsError(try ListingStore.validateAutoReup(.init(every_days: 2, hour: 9)))
        XCTAssertThrowsError(try ListingStore.validateAutoReup(.init(every_days: 1, hour: 10)))
        XCTAssertThrowsError(try ListingStore.validateAutoReup(.init(every_days: 7, hour: 0)))
    }
}

@testable import App
import Vapor
import XCTest

final class ListingValidationTests: XCTestCase {
    private typealias In = PostsController.CreateBody.ListingDataIn
    private typealias ItemIn = ListingStore.ItemIn

    private func item(_ title: String? = "Road bike", price: Int64? = 2_500_000, condition: String? = "good",
                      photos: [String]? = ["/uploads/a.jpg"]) -> ItemIn {
        ItemIn(title: title, price: price, condition: condition, image_urls: photos)
    }

    private func input(title: String? = nil, items: [ItemIn]? = nil,
                       location: String? = nil, autoReply: String? = nil, hide: Bool? = nil) -> In {
        In(title: title, items: items ?? [item()], location: location, autoReply: autoReply, hideFromFriends: hide)
    }

    func testValidListingIsTrimmedAndDefaulted() throws {
        let d = try ListingStore.validate(input(items: [item("  Road bike  ")], location: "  ", autoReply: " Yes, still here! "))
        XCTAssertEqual(d.title, "Road bike", "one item: its title is the headline")
        XCTAssertEqual(d.items.first?.title, "Road bike")
        XCTAssertNil(d.location, "a blank location is no location")
        XCTAssertEqual(d.autoReply, "Yes, still here!")
        XCTAssertFalse(d.hideFromFriends)
    }

    func testFreeIsAllowed() throws {
        XCTAssertEqual(try ListingStore.validate(input(items: [item(price: 0)])).items.first?.price, 0)
    }

    func testMissingDetailsAreRejected() {
        XCTAssertThrowsError(try ListingStore.validate(nil))
        XCTAssertThrowsError(try ListingStore.validate(In(title: "Sale", items: nil)))
        XCTAssertThrowsError(try ListingStore.validate(input(items: [])))
        XCTAssertThrowsError(try ListingStore.validate(input(items: [item("   ")])))
        XCTAssertThrowsError(try ListingStore.validate(input(items: [item(price: nil)])))
        XCTAssertThrowsError(try ListingStore.validate(input(items: [item(condition: nil)])))
    }

    func testSeveralItemsNeedAHeadline() throws {
        let two = [item("Doujinshi", price: 100_000), item("Bromide 🌸", price: 25_000, condition: "new")]
        XCTAssertThrowsError(try ListingStore.validate(input(items: two)))
        let d = try ListingStore.validate(input(title: " Shelf clear-out ✨ ", items: two))
        XCTAssertEqual(d.title, "Shelf clear-out ✨")
        XCTAssertEqual(d.items.map(\.title), ["Doujinshi", "Bromide 🌸"])
    }

    func testUpToTwentyItems() {
        XCTAssertNoThrow(try ListingStore.validate(input(title: "Sale", items: Array(repeating: item(), count: 20))))
        XCTAssertThrowsError(try ListingStore.validate(input(title: "Sale", items: Array(repeating: item(), count: 21))))
    }

    func testEachItemHasOneToSixPhotos() throws {
        XCTAssertThrowsError(try ListingStore.validateItems([item(photos: nil)]))
        XCTAssertThrowsError(try ListingStore.validateItems([item(photos: [])]))
        XCTAssertNoThrow(try ListingStore.validateItems([item(photos: (1...6).map { "/uploads/\($0).jpg" })]))
        XCTAssertThrowsError(try ListingStore.validateItems([item(photos: (1...7).map { "/uploads/\($0).jpg" })]))
        XCTAssertThrowsError(try ListingStore.validateItems([item(photos: ["https://evil.example/x.jpg"])]))
        var withAlt = item(photos: ["/uploads/a.jpg", "/uploads/b.jpg"])
        withAlt.image_alts = ["front"]
        let v = try ListingStore.validateItems([withAlt])
        XCTAssertEqual(v.first?.imageUrls.count, 2)
        XCTAssertEqual(v.first?.imageAlts?.count, 2, "alts line up with the photos")
    }

    func testItemIdsMustBeValidAndUnique() {
        let id = UUID().uuidString
        var a = item(), b = item()
        a.id = id; b.id = id
        XCTAssertThrowsError(try ListingStore.validateItems([a, b]))
        a.id = "nope"
        XCTAssertThrowsError(try ListingStore.validateItems([a]))
    }

    func testAskWaitIsRoundedUpToWholeMinutes() {
        let now = Date()
        XCTAssertEqual(ListingStore.askWaitMinutes(lastAsked: now, now: now), 20)
        XCTAssertEqual(ListingStore.askWaitMinutes(lastAsked: now.addingTimeInterval(-61), now: now), 19)
        XCTAssertEqual(ListingStore.askWaitMinutes(lastAsked: now.addingTimeInterval(-19 * 60 - 30), now: now), 1)
        XCTAssertEqual(ListingStore.askWaitMinutes(lastAsked: now.addingTimeInterval(-25 * 60), now: now), 1, "never says 0")
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
        XCTAssertThrowsError(try ListingStore.validate(input(items: [item(price: -1)])))
        XCTAssertThrowsError(try ListingStore.validate(input(items: [item(price: ListingStore.maxPrice + 1)])))
        XCTAssertThrowsError(try ListingStore.validate(input(items: [item(condition: "broken")])))
        XCTAssertThrowsError(try ListingStore.validate(input(items: [item(String(repeating: "a", count: 101))])))
        XCTAssertThrowsError(try ListingStore.validate(input(title: String(repeating: "a", count: 101))))
        XCTAssertThrowsError(try ListingStore.validate(input(autoReply: String(repeating: "a", count: 501))))
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

    // MARK: quantity (migration 138)

    func testItemQuantityDefaultsToOne() throws {
        XCTAssertEqual(try ListingStore.validateItems([item()]).first?.quantity, 1)
    }

    func testItemQuantityBounds() throws {
        func withQuantity(_ q: Int) -> ItemIn { var i = item(); i.quantity = q; return i }
        XCTAssertEqual(try ListingStore.validateItems([withQuantity(30)]).first?.quantity, 30)
        XCTAssertNoThrow(try ListingStore.validateItems([withQuantity(ListingStore.maxQuantity)]))
        XCTAssertThrowsError(try ListingStore.validateItems([withQuantity(0)]))
        XCTAssertThrowsError(try ListingStore.validateItems([withQuantity(-3)]))
        XCTAssertThrowsError(try ListingStore.validateItems([withQuantity(ListingStore.maxQuantity + 1)]))
    }
}

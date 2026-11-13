@testable import App
import XCTest

final class SaleBuyersTests: XCTestCase {
    private let a = "6F9619FF-8B86-D011-B42D-00C04FC964FF"
    private let b = "7d444840-9dc0-11d1-b245-5ffdce74fad2"

    func testLowercasesAndDeduplicates() throws {
        XCTAssertEqual(try MarketplaceController.saleBuyers([a, a.lowercased(), b]), [a.lowercased(), b])
    }

    func testRejectsEmptyTooManyAndNonUUIDs() {
        XCTAssertThrowsError(try MarketplaceController.saleBuyers([]))
        XCTAssertThrowsError(try MarketplaceController.saleBuyers([a, "nope"]))
        let many = (0..<51).map { _ in UUID().uuidString }
        XCTAssertThrowsError(try MarketplaceController.saleBuyers(many))
    }
}

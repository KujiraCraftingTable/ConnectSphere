@testable import App
import XCTest

final class DisplayNameTests: XCTestCase {
    func testLimitCountsCharactersSpacesIncluded() {
        XCTAssertTrue(UserStore.displayNameFits(String(repeating: "W", count: 30)))
        XCTAssertFalse(UserStore.displayNameFits(String(repeating: "W", count: 31)))
        // Accented Vietnamese letters count once each, decomposed or not.
        let name = "Nguyễn Thị Minh Khai Hoàng Anh"          // 30 with spaces
        XCTAssertEqual(name.count, 30)
        XCTAssertTrue(UserStore.displayNameFits(name))
        XCTAssertTrue(UserStore.displayNameFits(name.decomposedStringWithCanonicalMapping))
        XCTAssertFalse(UserStore.displayNameFits(name + "!"))
    }
}

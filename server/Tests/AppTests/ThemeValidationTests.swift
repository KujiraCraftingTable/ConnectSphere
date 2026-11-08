@testable import App
import XCTest

/// The palette ids PATCH /users/me accepts per mode.
final class ThemeValidationTests: XCTestCase {
    func testEachModeTakesOnlyItsOwnPalettes() {
        XCTAssertTrue(UsersController.isValidTheme("candy", mode: "hobby"))
        XCTAssertTrue(UsersController.isValidTheme("navy", mode: "work"))
        XCTAssertTrue(UsersController.isValidTheme("blue", mode: "hobby"))   // shared
        XCTAssertTrue(UsersController.isValidTheme("blue", mode: "work"))
        XCTAssertFalse(UsersController.isValidTheme("navy", mode: "hobby"))
        XCTAssertFalse(UsersController.isValidTheme("candy", mode: "work"))
    }

    func testUnknownOrMissingIsRejected() {
        XCTAssertFalse(UsersController.isValidTheme(nil, mode: "hobby"))
        XCTAssertFalse(UsersController.isValidTheme("", mode: "work"))
        XCTAssertFalse(UsersController.isValidTheme("'; DROP TABLE users", mode: "hobby"))
    }
}

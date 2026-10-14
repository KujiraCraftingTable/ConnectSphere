@testable import App
import Vapor
import XCTest

/// Email codes and what can be deleted.
final class AccountRulesTests: XCTestCase {
    func testEmailIsCleanedAndChecked() {
        XCTAssertEqual(AccountController.cleanEmail("  Kujira.G@Gmail.com "), "kujira.g@gmail.com")
        for bad in ["", "kujira", "kujira@", "@gmail.com", "a@b", "a@.com", "a@b.", "a b@c.com", "a@b@c.com"] {
            XCTAssertNil(AccountController.cleanEmail(bad), bad)
        }
    }

    func testWrongCodeSaysTriesLeft() {
        XCTAssertEqual(AccountCodeStore.wrongCodeMessage(triesLeft: 3), "That code isn't right — 3 tries left")
        XCTAssertEqual(AccountCodeStore.wrongCodeMessage(triesLeft: 1), "That code isn't right — 1 try left")
        XCTAssertEqual(AccountCodeStore.wrongCodeMessage(triesLeft: 0), "Too many wrong codes. Ask for a new one")
    }

    func testAPersonaGoesOnlyWhileTheOtherStays() {
        XCTAssertNoThrow(try AccountController.checkPersona("work", hobby: true, work: true))
        XCTAssertThrowsError(try AccountController.checkPersona("work", hobby: true, work: false))  // none to delete
        XCTAssertThrowsError(try AccountController.checkPersona("hobby", hobby: true, work: false)) // the only one
    }
}

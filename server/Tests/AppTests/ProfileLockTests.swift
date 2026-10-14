@testable import App
import Vapor
import XCTest

/// Who gets only the locked view of a persona.
final class ProfileLockTests: XCTestCase {
    func testOnlyStrangersAreLockedOut() {
        XCTAssertTrue(ProfileLock.isLockedOut(locked: true, isSelf: false, connected: false))
        XCTAssertFalse(ProfileLock.isLockedOut(locked: true, isSelf: false, connected: true))   // a connection
        XCTAssertFalse(ProfileLock.isLockedOut(locked: true, isSelf: true, connected: false))   // yourself
        XCTAssertFalse(ProfileLock.isLockedOut(locked: false, isSelf: false, connected: false)) // not locked
    }
}

@testable import App
import XCTest

/// Chat spam is spotted by behaviour, never by reading messages.
final class SpamSignalsTests: XCTestCase {
    func testOrdinaryUseIsNotSpam() {
        XCTAssertNil(SpamSignals.reason(.init(sameTextChats: 1, linkChats: 1, strangerChats: 4, isNewAccount: false)))
        XCTAssertNil(SpamSignals.reason(.init(sameTextChats: 4, linkChats: 2, strangerChats: 7, isNewAccount: true)))
    }

    func testTheSameTextToManyStrangers() {
        XCTAssertEqual(SpamSignals.reason(.init(sameTextChats: 5)), "same_message")
    }

    func testLinksToSeveralStrangers() {
        XCTAssertEqual(SpamSignals.reason(.init(linkChats: 3)), "links")
    }

    func testANewAccountMessagingACrowd() {
        XCTAssertEqual(SpamSignals.reason(.init(strangerChats: 8, isNewAccount: true)), "new_account_burst")
        XCTAssertNil(SpamSignals.reason(.init(strangerChats: 8, isNewAccount: false)))
        XCTAssertEqual(SpamSignals.reason(.init(strangerChats: 25, isNewAccount: false)), "burst")
    }
}

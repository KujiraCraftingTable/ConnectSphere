import XCTest
@testable import App

final class MessageRequestTests: XCTestCase {
    func testStarterGetsThreeMessagesBeforeAcceptance() {
        XCTAssertEqual(MessageRequests.decide(sent: 0), .open)
        XCTAssertEqual(MessageRequests.decide(sent: 2), .open)
        XCTAssertEqual(MessageRequests.decide(sent: 3), .limitReached)
    }

    func testOnlyRealIdsAreEmbeddedInSQL() {
        XCTAssertEqual(MessageRequests.quoted("B154ECEE-0B76-4D01-B947-9904B0689585"),
                       "'b154ecee-0b76-4d01-b947-9904b0689585'::uuid")
        XCTAssertEqual(MessageRequests.quoted("x'; DROP TABLE users;--"), "NULL::uuid")
    }
}

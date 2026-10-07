import XCTest
@testable import App

final class ReplyPlacementTests: XCTestCase {
    typealias P = InteractionsController.ReplyPlacement

    func testReplyingToACommentOrAReplyNestsUnderIt() {
        XCTAssertEqual(InteractionsController.replyPlacement(targetID: "root", targetParentID: nil, targetDepth: 1),
                       P(parentID: "root", replyToID: "root"))
        XCTAssertEqual(InteractionsController.replyPlacement(targetID: "r1", targetParentID: "root", targetDepth: 2),
                       P(parentID: "r1", replyToID: "r1"))
    }

    func testReplyingToAThirdLevelReplyStaysAtThatLevel() {
        // Stored beside the reply it answers (same parent), still naming it.
        XCTAssertEqual(InteractionsController.replyPlacement(targetID: "r2", targetParentID: "r1", targetDepth: 3),
                       P(parentID: "r1", replyToID: "r2"))
    }
}

@testable import App
import Vapor
import XCTest

/// What a community's staff may decide on a report (CommunityReports.swift).
final class CommunityReportDecisionTests: XCTestCase {
    func testPostDecisionsForModerators() throws {
        for d in ["keep", "remove", "remove_warn"] {
            XCTAssertEqual(try ReportsController.validDecision(d, targetType: "post", role: "moderator"), d)
        }
    }

    func testOnlyTheAdminBans() throws {
        XCTAssertEqual(try ReportsController.validDecision("remove_ban", targetType: "post", role: "admin"), "remove_ban")
        XCTAssertEqual(try ReportsController.validDecision("ban", targetType: "member", role: "admin"), "ban")
        for (d, type) in [("remove_ban", "post"), ("ban", "member")] {
            XCTAssertThrowsError(try ReportsController.validDecision(d, targetType: type, role: "moderator")) { error in
                XCTAssertEqual((error as? Abort)?.status, .forbidden)
            }
        }
    }

    func testDecisionMustFitTheTarget() {
        // A member has no post to remove; a post isn't banned directly.
        for (d, type) in [("remove", "member"), ("remove_warn", "member"), ("ban", "post"),
                          ("strike", "post"), ("", "post")] {
            XCTAssertThrowsError(try ReportsController.validDecision(d, targetType: type, role: "admin"), "\(d) on \(type)") { error in
                XCTAssertEqual((error as? Abort)?.status, .badRequest)
            }
        }
        XCTAssertThrowsError(try ReportsController.validDecision(nil, targetType: "post", role: "admin"))
    }
}

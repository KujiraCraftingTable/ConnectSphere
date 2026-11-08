@testable import App
import XCTest

/// The shared policy list (migration 089): what can be reported, with which
/// reasons, and which reports community staff judge alone.
final class ModerationPolicyTests: XCTestCase {
    func testSeverityPutsChildSafetyFirstAndHouseRulesLast() {
        XCTAssertEqual(ModerationPolicy.childSafety.severity, 0)
        XCTAssertEqual(ModerationPolicy.nuditySexual.severity, 1)
        XCTAssertEqual(ModerationPolicy.hate.severity, 2)
        XCTAssertEqual(ModerationPolicy.offTopic.severity, 3)
    }

    func testValidReportTrimsDetail() throws {
        let (t, r, d) = try ReportRules.validate(target: "comment", reason: "harassment", detail: "  mean  ")
        XCTAssertEqual(t, .comment)
        XCTAssertEqual(r, .harassment)
        XCTAssertEqual(d, "mean")
        XCTAssertNil(try ReportRules.validate(target: "post", reason: "spam", detail: "   ").2)
    }

    func testReasonsDependOnTarget() {
        XCTAssertNoThrow(try ReportRules.validate(target: "dating_profile", reason: "underage", detail: nil))
        XCTAssertThrowsError(try ReportRules.validate(target: "post", reason: "underage", detail: nil)) {
            XCTAssertEqual($0 as? ReportRules.Problem, .badReason)
        }
        XCTAssertNoThrow(try ReportRules.validate(target: "post", reason: "off_topic", detail: nil))
        XCTAssertThrowsError(try ReportRules.validate(target: "message", reason: "off_topic", detail: nil))
        XCTAssertNoThrow(try ReportRules.validate(target: "user", reason: "impersonation", detail: nil))
    }

    func testRejectsUnknownTargetReasonAndLongDetail() {
        XCTAssertThrowsError(try ReportRules.validate(target: "listing", reason: "spam", detail: nil)) {
            XCTAssertEqual($0 as? ReportRules.Problem, .badTarget)
        }
        XCTAssertThrowsError(try ReportRules.validate(target: "post", reason: "rude", detail: nil)) {
            XCTAssertEqual($0 as? ReportRules.Problem, .badReason)
        }
        XCTAssertThrowsError(try ReportRules.validate(target: "post", reason: "spam", detail: String(repeating: "a", count: 501))) {
            XCTAssertEqual($0 as? ReportRules.Problem, .detailTooLong)
        }
    }

    func testHarmIsNeverLeftToCommunityStaffAlone() {
        for p in [ModerationPolicy.childSafety, .nuditySexual, .violence, .selfHarm, .scam, .hate, .harassment] {
            XCTAssertFalse(ReportRules.communityOnly.contains(p), p.rawValue)
        }
    }

    func testCommunityReasonsFitTheOldTable() {
        let allowed: Set = ["spam", "harassment", "hate_speech", "misinformation", "off_topic", "other"]
        for p in ModerationPolicy.allCases {
            XCTAssertTrue(allowed.contains(ReportRules.communityReason(p)), p.rawValue)
        }
    }

    // MARK: enforcement

    func testStrikeLadderWarnsFirstThenEscalates() {
        XCTAssertNil(Enforcement.restrictionDays(activeStrikes: 1))
        XCTAssertEqual(Enforcement.restrictionDays(activeStrikes: 2), 1)
        XCTAssertEqual(Enforcement.restrictionDays(activeStrikes: 3), 3)
        XCTAssertEqual(Enforcement.restrictionDays(activeStrikes: 4), 7)
        XCTAssertEqual(Enforcement.restrictionDays(activeStrikes: 9), 30)
    }

    func testChildSafetyStrikeBecomesABan() {
        XCTAssertEqual(Enforcement.escalate(.removeStrike, policy: .childSafety), .ban)
        XCTAssertEqual(Enforcement.escalate(.removeStrike, policy: .spam), .removeStrike)
        XCTAssertEqual(Enforcement.escalate(.keep, policy: .childSafety), .keep)
    }

    func testOnlyKeepLeavesContentUp() {
        XCTAssertEqual(ModerationDecision.allCases.filter { !$0.removesContent }, [.keep])
    }

    func testAppealWindowIsThirtyDays() {
        let now = Date()
        XCTAssertTrue(Enforcement.canAppeal(decidedAt: now.addingTimeInterval(-29 * 86_400), now: now))
        XCTAssertFalse(Enforcement.canAppeal(decidedAt: now.addingTimeInterval(-31 * 86_400), now: now))
    }

    func testBannedAccountsReachOnlyAppealsAndStatus() {
        XCTAssertTrue(AuthMiddleware.openToBanned("/api/appeals"))
        XCTAssertTrue(AuthMiddleware.openToBanned("/api/account-status"))
        XCTAssertFalse(AuthMiddleware.openToBanned("/api/posts"))
        // Open since bans are per mode (migration 106): the app loads the
        // account to show the ban notice and switch to the mode still allowed.
        XCTAssertTrue(AuthMiddleware.openToBanned("/api/auth/me"))
    }
}

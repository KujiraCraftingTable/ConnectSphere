@testable import App
import XCTest

/// Per-mode bans and warnings (migration 106).
final class AccountBansTests: XCTestCase {
    func testBanIsActiveUntilItEndsOrIsLifted() {
        let now = Date()
        XCTAssertTrue(AccountBans.isActive(liftedAt: nil, bannedUntil: nil, now: now), "permanent")
        XCTAssertTrue(AccountBans.isActive(liftedAt: nil, bannedUntil: now.addingTimeInterval(60), now: now))
        XCTAssertFalse(AccountBans.isActive(liftedAt: nil, bannedUntil: now.addingTimeInterval(-60), now: now), "ran out")
        XCTAssertFalse(AccountBans.isActive(liftedAt: now, bannedUntil: nil, now: now), "overturned")
    }

    func testOnlyTheOfferedLengths() {
        XCTAssertTrue(AccountBans.validDays(nil))
        for d in [7, 30, 90, 365] { XCTAssertTrue(AccountBans.validDays(d)) }
        for d in [0, 1, 14, 400] { XCTAssertFalse(AccountBans.validDays(d)) }
    }

    func testBannedInOneModeOnlyBlocksThatMode() {
        let path = "/api/posts"
        XCTAssertEqual(AuthMiddleware.refusal(bannedModes: ["hobby"], requestMode: "hobby", path: path),
                       AuthMiddleware.bannedInModeMessage)
        XCTAssertNil(AuthMiddleware.refusal(bannedModes: ["hobby"], requestMode: "work", path: path))
        XCTAssertNil(AuthMiddleware.refusal(bannedModes: [], requestMode: "hobby", path: path))
    }

    func testDroppingOrFakingTheModeHeaderDoesNotSlipABan() {
        let path = "/api/posts"
        for header in [nil, "", "dating"] as [String?] {
            XCTAssertEqual(AuthMiddleware.refusal(bannedModes: ["hobby"], requestMode: header, path: path),
                           AuthMiddleware.bannedInModeMessage, header ?? "nil")
        }
        XCTAssertEqual(AuthMiddleware.refusal(bannedModes: ["hobby"], requestMode: "work", queryMode: "hobby", path: path),
                       AuthMiddleware.bannedInModeMessage)
        XCTAssertNil(AuthMiddleware.refusal(bannedModes: ["hobby"], requestMode: "work", queryMode: "work", path: path))
        XCTAssertNil(AuthMiddleware.refusal(bannedModes: [], requestMode: nil, path: path))
    }

    func testBannedEverywhereIsTheWholeAccount() {
        XCTAssertEqual(AuthMiddleware.refusal(bannedModes: ["hobby", "work"], requestMode: nil, path: "/api/posts"),
                       AuthMiddleware.bannedMessage)
    }

    func testTheNoticeAndAppealsStayOpen() {
        for path in ["/api/account-status", "/api/appeals", "/api/auth/me", "/api/users/me/default-mode"] {
            XCTAssertNil(AuthMiddleware.refusal(bannedModes: ["hobby", "work"], requestMode: "hobby", path: path), path)
        }
    }
}

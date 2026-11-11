@testable import App
import XCTest

/// Upload content checks, the re-up wait, reporter outcomes and per-mode
/// restrictions (the Hobby QA Medium fixes).
final class MediumFixesTests: XCTestCase {
    func testUploadsMustLookLikeWhatTheyClaim() {
        XCTAssertTrue(MediaSniffer.matches([0xFF, 0xD8, 0xFF, 0xE0, 0x00], ext: "jpg"))
        XCTAssertTrue(MediaSniffer.matches([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00], ext: "png"))
        let heic: [UInt8] = [0, 0, 0, 24] + Array("ftypheic".utf8) + [0, 0, 0, 0]
        XCTAssertTrue(MediaSniffer.matches(heic, ext: "heic"))
        let mp4: [UInt8] = [0, 0, 0, 24] + Array("ftypisom".utf8)
        XCTAssertTrue(MediaSniffer.matches(mp4, ext: "mp4"))
        XCTAssertTrue(MediaSniffer.matches(Array("RIFF\u{0}\u{0}\u{0}\u{0}WEBPVP8 ".utf8), ext: "webp"))

        let text = Array("hello, not a photo".utf8)
        for ext in ["jpg", "png", "webp", "heic", "mp4", "mov", "gif", "m4a"] {
            XCTAssertFalse(MediaSniffer.matches(text, ext: ext), ext)
        }
        XCTAssertFalse(MediaSniffer.matches([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A], ext: "jpg"), "a PNG isn't a JPEG")
        XCTAssertFalse(MediaSniffer.matches([], ext: "jpg"))
        XCTAssertFalse(MediaSniffer.matches(heic, ext: "svg"))
    }

    func testReupWaitsEightHours() {
        let now = Date()
        XCTAssertEqual(ListingStore.reupWait(lastListed: now.addingTimeInterval(-(4 * 3600 + 40 * 60)), now: now), "3h 20m")
        XCTAssertEqual(ListingStore.reupWait(lastListed: now.addingTimeInterval(-(8 * 3600 - 90)), now: now), "2m")
        XCTAssertNil(ListingStore.reupWait(lastListed: now.addingTimeInterval(-8 * 3600), now: now))
        XCTAssertNil(ListingStore.reupWait(lastListed: now.addingTimeInterval(-3 * 86400), now: now))
    }

    func testReportersHearWhatActuallyHappened() {
        XCTAssertEqual(ReportOutcome.of(decision: .keep, targetType: "post"), "kept")
        XCTAssertEqual(ReportOutcome.of(decision: .restrict, targetType: "post"), "removed")
        XCTAssertEqual(ReportOutcome.of(decision: .ban, targetType: "post"), "removed")
        XCTAssertEqual(ReportOutcome.of(decision: .ban, targetType: "user"), "action_taken")
        XCTAssertEqual(ReportOutcome.of(decision: .warn, targetType: "user"), "action_taken")
        XCTAssertEqual(ReportOutcome.of(decision: .remove, targetType: "user"), "removed")
    }

    func testARestrictionStaysInItsMode() {
        let soon = Date().addingTimeInterval(3600), later = Date().addingTimeInterval(7200)
        let hobbyOnly = ["hobby": soon]
        XCTAssertEqual(AccountRestrictions.until(in: "hobby", of: hobbyOnly), soon)
        XCTAssertNil(AccountRestrictions.until(in: "work", of: hobbyOnly))
        XCTAssertEqual(AccountRestrictions.until(in: "HOBBY", of: hobbyOnly), soon)
        // No mode known: the longest one applies, so nothing slips through.
        XCTAssertEqual(AccountRestrictions.until(in: nil, of: ["hobby": soon, "work": later]), later)
        XCTAssertEqual(AccountRestrictions.until(in: "dating", of: hobbyOnly), soon)
        XCTAssertNil(AccountRestrictions.until(in: nil, of: [:]))
    }
}

/// The Hobby QA Low fixes: input checks, read-only restrictions, own reports.
final class LowFixesTests: XCTestCase {
    func testPostLinksAreWebPagesOnly() throws {
        XCTAssertEqual(try MediaPath.webLink(" https://example.com/a "), "https://example.com/a")
        XCTAssertNil(try MediaPath.webLink("  "))
        for bad in ["javascript:alert(1)", "tel:0123", "sms:1", "shortcuts://run", "http://", "ftp://x.com"] {
            XCTAssertThrowsError(try MediaPath.webLink(bad), bad)
        }
    }

    func testVoiceNotesNeedARealLength() throws {
        XCTAssertThrowsError(try MessagesController.validateVoice(type: "voice", seconds: -3, waveform: nil))
        XCTAssertThrowsError(try MessagesController.validateVoice(type: "voice", seconds: 0, waveform: nil))
        XCTAssertThrowsError(try MessagesController.validateVoice(type: "voice", seconds: nil, waveform: nil))
        XCTAssertThrowsError(try MessagesController.validateVoice(type: "voice", seconds: 5, waveform: [2]))
        XCTAssertEqual(try MessagesController.validateVoice(type: "voice", seconds: 5, waveform: [0.2]).seconds, 5)
        // Other types never carry voice fields.
        XCTAssertNil(try MessagesController.validateVoice(type: "text", seconds: -3, waveform: [9]).seconds)
    }

    func testOnlyTheAppsChatThemes() {
        XCTAssertTrue(MessagesController.chatThemes.contains("deep-purple"))
        XCTAssertFalse(MessagesController.chatThemes.contains("<script>"))
    }

    func testRestrictedAccountsAreReadOnly() {
        // Reading, settings and safety tools stay open.
        XCTAssertTrue(Restrictions.allows(method: "GET", path: "/api/posts"))
        XCTAssertTrue(Restrictions.allows(method: "PATCH", path: "/api/users/me"))
        XCTAssertTrue(Restrictions.allows(method: "POST", path: "/api/reports"))
        XCTAssertTrue(Restrictions.allows(method: "POST", path: "/api/appeals"))
        XCTAssertTrue(Restrictions.allows(method: "POST", path: "/api/users/abc/block"))
        XCTAssertTrue(Restrictions.allows(method: "PUT", path: "/api/messages/conversations/abc/read"))
        XCTAssertTrue(Restrictions.allows(method: "POST", path: "/api/notifications/abc/read"))
        // Everything that changes or interacts is refused.
        for (m, p) in [("POST", "/api/posts"), ("POST", "/api/posts/abc/comments"), ("POST", "/api/posts/abc/like"),
                       ("POST", "/api/messages/conversations/abc/messages"), ("POST", "/api/connections/request"),
                       ("POST", "/api/listings/abc/items/def/ask"), ("DELETE", "/api/posts/abc"),
                       ("DELETE", "/api/communities/abc/leave"), ("POST", "/api/users/me/highlights")] {
            XCTAssertFalse(Restrictions.allows(method: m, path: p), "\(m) \(p)")
        }
    }

    func testStaffDontJudgeTheirOwnReports() {
        XCTAssertTrue(ReportsController.mayDecide(isReporter: false, role: "moderator", moderatorCount: 1))
        XCTAssertFalse(ReportsController.mayDecide(isReporter: true, role: "moderator", moderatorCount: 2))
        XCTAssertFalse(ReportsController.mayDecide(isReporter: true, role: "admin", moderatorCount: 1))
        XCTAssertTrue(ReportsController.mayDecide(isReporter: true, role: "admin", moderatorCount: 0))
    }
}

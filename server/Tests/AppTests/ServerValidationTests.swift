@testable import App
import Vapor
import XCTest

/// Input checks that used to reach the database (a 500) or let something
/// through that should have been refused (QA report 2026-11-06).
final class ServerValidationTests: XCTestCase {
    // MARK: media must be our own upload

    private let ours: (String) -> Bool = { _ in true }

    func testOnlyOwnUploadsAreAccepted() throws {
        XCTAssertEqual(try MediaPath.uploaded("/uploads/a.jpg", exists: ours), "/uploads/a.jpg")
        XCTAssertEqual(try MediaPath.uploaded("http://localhost:3000/uploads/a.jpg", exists: ours), "/uploads/a.jpg")
        XCTAssertNil(try MediaPath.uploaded("  ", exists: ours))
        XCTAssertNil(try MediaPath.uploaded(nil as String?, exists: ours))
        for bad in ["https://tracker.example/pixel.gif", "javascript:alert(1)", "/etc/passwd", "uploads/a.jpg",
                    "/uploads/../secret", "/uploads/%2e%2e/secret"] {
            XCTAssertThrowsError(try MediaPath.uploaded(bad, exists: ours), bad)
        }
        // Someone else's /uploads/ folder: not a file we hold.
        XCTAssertThrowsError(try MediaPath.uploaded("https://other.site/uploads/b.jpg", exists: { $0 == "/uploads/a.jpg" }))
    }

    func testPostsAndListingsCannotReuseChatOrCVFiles() throws {
        XCTAssertThrowsError(try MediaPath.uploaded("/uploads/messages/1730000000000-ab.jpg", exists: ours))
        XCTAssertThrowsError(try MediaPath.uploaded("/uploads/cv/x.pdf", exists: ours))
        XCTAssertEqual(try MediaPath.uploaded("/uploads/messages/1730000000000-ab.jpg", scope: .chat, exists: ours),
                       "/uploads/messages/1730000000000-ab.jpg")
        // A chat attachment link may still carry the viewer's token; it isn't stored.
        XCTAssertEqual(try MediaPath.uploaded("/uploads/messages/v.m4a?token=abc", scope: .chat, exists: ours),
                       "/uploads/messages/v.m4a")
        XCTAssertThrowsError(try MediaPath.uploaded("https://evil.example/x.png", scope: .chat, exists: ours))
    }

    func testListsDropBlanksAndRejectOutsideLinks() throws {
        XCTAssertEqual(try MediaPath.uploaded(["", "/uploads/a.jpg"], exists: ours), ["/uploads/a.jpg"])
        XCTAssertThrowsError(try MediaPath.uploaded(["/uploads/a.jpg", "https://evil.example/a.jpg"], exists: ours))
        XCTAssertThrowsError(try PostsController.normalizeImageUrls(["https://evil.example/a.jpg"]))
        XCTAssertNil(try PostsController.normalizeImageUrls([]))
    }

    // MARK: job posts are checked before the post is written

    func testJobBasicsAreCheckedUpFront() throws {
        let ok = try JobStore.validateBasics(title: " QA Tester ", company: nil, location: "", employmentType: "full_time",
                                             salaryRange: nil, applicationDeadline: "2027-01-31T00:00:00Z")
        XCTAssertEqual(ok.title, "QA Tester")
        XCTAssertNil(ok.location)
        XCTAssertEqual(ok.applicationDeadline, "2027-01-31")

        XCTAssertThrowsError(try JobStore.validateBasics(title: "x", company: nil, location: nil, employmentType: "boss",
                                                         salaryRange: nil, applicationDeadline: nil))
        for bad in ["not-a-date", "2027-02-30", "31/01/2027"] {
            XCTAssertThrowsError(try JobStore.validateBasics(title: "x", company: nil, location: nil, employmentType: nil,
                                                             salaryRange: nil, applicationDeadline: bad), bad)
        }
        XCTAssertThrowsError(try JobStore.validateBasics(title: "  ", company: nil, location: nil, employmentType: nil,
                                                         salaryRange: nil, applicationDeadline: nil))
        XCTAssertThrowsError(try JobStore.validateBasics(title: String(repeating: "t", count: 151), company: nil, location: nil,
                                                         employmentType: nil, salaryRange: nil, applicationDeadline: nil))
        XCTAssertThrowsError(try JobStore.validateBasics(title: "x", company: nil, location: nil, employmentType: nil,
                                                         salaryRange: String(repeating: "9", count: 101), applicationDeadline: nil))
        for type in JobStore.employmentTypes {
            XCTAssertNoThrow(try JobStore.validateBasics(title: "x", company: nil, location: nil, employmentType: type,
                                                         salaryRange: nil, applicationDeadline: nil), type)
        }
    }

    // MARK: privacy

    func testUnknownPrivacyIsRefusedNotMadePublic() throws {
        XCTAssertEqual(try PostStore.validatedPrivacy("only_me"), "only_me")
        XCTAssertEqual(try PostStore.validatedPrivacy("friends"), "friends")
        XCTAssertNil(try PostStore.validatedPrivacy(nil))
        XCTAssertNil(try PostStore.validatedPrivacy(""))
        for bad in ["private", "everyone", "PUBLIC"] {
            XCTAssertThrowsError(try PostStore.validatedPrivacy(bad), bad)
        }
    }

    // MARK: sessions

    func testATokenDiesWithItsAccountAndWithAReset() {
        XCTAssertTrue(Session.accepts(iat: 1_000, deletedAt: nil, validAfter: nil))
        XCTAssertFalse(Session.accepts(iat: 1_000, deletedAt: Date(), validAfter: nil))
        XCTAssertFalse(Session.accepts(iat: 999, deletedAt: nil, validAfter: 1_000), "issued before the reset")
        XCTAssertTrue(Session.accepts(iat: 1_000, deletedAt: nil, validAfter: 1_000), "issued in the reset's second or later")
        XCTAssertTrue(Session.accepts(iat: 2_000, deletedAt: nil, validAfter: 1_000))
    }

    // MARK: passwords and sign-in names

    func testPasswordLengthIsBoundedByWhatBcryptReads() throws {
        XCTAssertNoThrow(try AuthController.validatePassword("12345678"))
        XCTAssertNoThrow(try AuthController.validatePassword(String(repeating: "p", count: 72)))
        XCTAssertThrowsError(try AuthController.validatePassword("1234567"))
        XCTAssertThrowsError(try AuthController.validatePassword(String(repeating: "p", count: 73)))
        // 40 two-byte characters are 80 bytes: counted in bytes, as bcrypt does.
        XCTAssertThrowsError(try AuthController.validatePassword(String(repeating: "é", count: 40)))
    }

    func testSignInAcceptsTheAtSign() {
        XCTAssertEqual(AuthController.loginIdentifier("@Kujira_Sigma "), "kujira_sigma")
        XCTAssertEqual(AuthController.loginIdentifier("Kujira@Example.com"), "kujira@example.com")
        XCTAssertEqual(AuthController.loginIdentifier(nil), "")
    }

    // MARK: lengths that the database would reject with a 500

    func testCommentLengthCountsCodePointsLikePostgres() throws {
        XCTAssertNoThrow(try InteractionsController.validateCommentLength(String(repeating: "c", count: 1000)))
        XCTAssertThrowsError(try InteractionsController.validateCommentLength(String(repeating: "c", count: 1001)))
        // One grapheme (a family emoji) is several code points.
        XCTAssertThrowsError(try InteractionsController.validateCommentLength(String(repeating: "👨‍👩‍👧", count: 201)))
    }

    func testAIQueryIsTrimmedAndBounded() throws {
        XCTAssertEqual(try SearchController.cleanQuery("  piano \n"), "piano")
        XCTAssertEqual(try SearchController.cleanQuery("   \n\t "), "")
        XCTAssertEqual(try SearchController.cleanQuery(nil), "")
        XCTAssertNoThrow(try SearchController.cleanQuery(String(repeating: "q", count: SearchController.maxQueryLength)))
        XCTAssertThrowsError(try SearchController.cleanQuery(String(repeating: "q", count: SearchController.maxQueryLength + 1)))
    }

    func testBirthdayIsCheckedBeforeAChangeIsSpent() {
        let today = JSONCoding.dateOnly.date(from: "2026-11-06")!
        XCTAssertNil(BirthdayRules.rejection("2000-01-15", today: today))
        XCTAssertEqual(BirthdayRules.rejection("2099-01-01", today: today), BirthdayRules.futureReason)
        XCTAssertEqual(BirthdayRules.rejection("15/01/2000", today: today), BirthdayRules.invalidReason)
        XCTAssertEqual(BirthdayRules.rejection("2000-02-30", today: today), BirthdayRules.invalidReason)
        XCTAssertEqual(BirthdayRules.rejection("2015-01-01", today: today), BirthdayRules.underageReason)
    }

    func testCommunityIconAndColour() throws {
        XCTAssertNoThrow(try CommunitiesController.validateAppearance(icon: "🎮", color: "#7F5AF0"))
        XCTAssertNoThrow(try CommunitiesController.validateAppearance(icon: nil, color: nil))
        XCTAssertThrowsError(try CommunitiesController.validateAppearance(icon: String(repeating: "🎮", count: 11), color: nil))
        XCTAssertThrowsError(try CommunitiesController.validateAppearance(icon: "", color: nil))
        XCTAssertThrowsError(try CommunitiesController.validateAppearance(icon: " 🎮", color: nil))
        for bad in ["red", "7F5AF0", "#7F5AF", "#7F5AF0F", "#GGGGGG", "'; DROP"] {
            XCTAssertThrowsError(try CommunitiesController.validateAppearance(icon: nil, color: bad), bad)
        }
    }

    func testExperienceMonthTakesDigitsOnly() {
        XCTAssertNotNil(ExperiencesController.month("2024-03"))
        for bad in ["2024-+3", "2024--1", "+024-03", "2024-3 ", "2024-13", "2024-00"] {
            XCTAssertNil(ExperiencesController.month(bad), bad)
        }
    }

    // MARK: chat

    func testMessageTypesMatchTheDatabaseCheck() {
        for ok in ["text", "image", "video", "voice", "album", "meeting", "poll", "post", "community"] {
            XCTAssertTrue(MessagesController.messageTypes.contains(ok), ok)
        }
        XCTAssertFalse(MessagesController.messageTypes.contains("bogus"))
    }

    func testMeetingReminderMustFallBeforeTheMeetingAndAfterNow() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)   // 2027-01-15
        func meeting(reminder: String?, title: String = "Coffee", location: String? = nil) throws -> ValidatedMeeting {
            try MessagesController.validateMeetingProposal(
                title: title, location: location, startsAt: "2027-02-01T10:00:00Z", endsAt: nil,
                reminderOffset: nil, reminderAt: reminder, now: now)
        }
        XCTAssertNoThrow(try meeting(reminder: nil))
        XCTAssertNoThrow(try meeting(reminder: "2027-01-31T10:00:00Z"))
        XCTAssertThrowsError(try meeting(reminder: "2019-01-01T10:00:00Z"), "in the past")
        XCTAssertThrowsError(try meeting(reminder: "2028-01-01T10:00:00Z"), "after the start")
        XCTAssertThrowsError(try meeting(reminder: nil, title: String(repeating: "t", count: 201)))
        XCTAssertThrowsError(try meeting(reminder: nil, location: String(repeating: "l", count: 301)))
    }

    func testAMeetingMinutesAwayCanBeProposedWithAShortReminder() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)   // 2027-01-15T08:00:00Z
        func meeting(_ offset: String) throws -> ValidatedMeeting {
            try MessagesController.validateMeetingProposal(
                title: "Call", location: nil, startsAt: "2027-01-15T08:10:00Z", endsAt: nil,
                reminderOffset: offset, reminderAt: nil, now: now)
        }
        XCTAssertEqual(try meeting("at_start").reminderAt, "2027-01-15T08:10:00.000Z")
        XCTAssertEqual(try meeting("1_hour_before").reminderAt, "2027-01-15T07:10:00.000Z")
        XCTAssertThrowsError(try meeting("2_hours_before"), "not a preset")
    }

    // MARK: translation

    func testAnEchoedTranslationIsNotATranslation() {
        XCTAssertTrue(TranslationService.isUnchanged("Looking for a running buddy", from: "Looking for a running buddy"))
        XCTAssertTrue(TranslationService.isUnchanged("looking for  a running buddy ", from: "Looking for a running buddy"))
        XCTAssertFalse(TranslationService.isUnchanged("Đang tìm bạn chạy bộ", from: "Looking for a running buddy"))
    }

    // MARK: single image_url and community icon (QA re-check 2026-11-07)

    func testThumbnailIsOurUploadOrALinkPreviewImage() throws {
        let other: (String) -> Bool = { _ in false }
        XCTAssertEqual(try MediaPath.thumbnail("/uploads/a.jpg", hasLink: false, exists: ours), "/uploads/a.jpg")
        XCTAssertEqual(try MediaPath.thumbnail("https://site.example/og.png", hasLink: true, exists: other), "https://site.example/og.png")
        XCTAssertNil(try MediaPath.thumbnail(" ", hasLink: false, exists: other))
        // A bare external image, or a non-web scheme, is refused.
        XCTAssertThrowsError(try MediaPath.thumbnail("https://evil.example/x.png", hasLink: false, exists: other))
        XCTAssertThrowsError(try MediaPath.thumbnail("javascript:alert(1)", hasLink: true, exists: other))
        XCTAssertThrowsError(try MediaPath.thumbnail("data:image/png;base64,AAAA", hasLink: true, exists: other))
        XCTAssertThrowsError(try MediaPath.thumbnail("/etc/passwd", hasLink: true, exists: other))
    }

    func testCommunityIconMustBeAnEmoji() throws {
        for ok in ["👥", "🏃‍♂️", "❤️", "🇻🇳"] {
            XCTAssertNoThrow(try CommunitiesController.validateAppearance(icon: ok, color: nil), ok)
        }
        for bad in ["<b>", "abc", "1", "#", "👥a", " ", ""] {
            XCTAssertThrowsError(try CommunitiesController.validateAppearance(icon: bad, color: nil), bad)
        }
    }
}

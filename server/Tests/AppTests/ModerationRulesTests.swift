@testable import App
import XCTest

/// The word rules: rude and dangerous text is caught however it's typed, and
/// ordinary Vietnamese that merely *looks* rude without its accents is not.
final class ModerationRulesTests: XCTestCase {
    private func v(_ s: String) -> ModerationRules.Verdict { ModerationRules.verdict(s) }

    func testOrdinaryTextIsClean() {
        for s in ["Chào bạn, hôm nay thế nào?", "DM me later", "cảm ơn các bạn", "nuôi lợn ở quê", "Sussex cricket",
                  "Scunthorpe is a town", "bạn đam mê gì vậy", "mặt dày thật", "con gái gọi mẹ", "classic assistant",
                  "mai đi cà phê không?", "I love this photo"] {
            XCTAssertEqual(v(s), .clean, s)
        }
    }

    func testProfanityNudgesWhateverTheSpelling() {
        for s in ["địt mẹ mày", "dit me may", "Đ.M", "f u c k", "fuuuuck you", "sh1t", "vcl quá", "thằng chó", "đồ ngu", "WTF"] {
            XCTAssertEqual(v(s), .nudge, s)
        }
    }

    func testThreatsAndSlursAreBlocked() {
        XCTAssertEqual(v("tao sẽ giết mày"), .block(.violence))
        XCTAssertEqual(v("tao se giet may"), .block(.violence))
        XCTAssertEqual(v("I'll kill you"), .block(.violence))
        XCTAssertEqual(v("go kill yourself"), .block(.harassment))
        XCTAssertEqual(v("nigger"), .block(.hate))
        XCTAssertEqual(v("child porn for sale"), .block(.childSafety))
        XCTAssertEqual(v("khiêu dâm trẻ em"), .block(.childSafety))
    }

    func testBlockWinsOverNudge() {
        XCTAssertEqual(v("địt mẹ tao sẽ giết mày"), .block(.violence))
    }

    func testInterestPickerStaysStrict() {
        XCTAssertTrue(ModerationRules.isListedForInterests("đụ má"))
        XCTAssertTrue(ModerationRules.isListedForInterests("ma túy đá"))
        XCTAssertTrue(ModerationRules.isListedForInterests("phim sex"))
        XCTAssertFalse(ModerationRules.isListedForInterests("chơi các game"))
        XCTAssertFalse(ModerationRules.isListedForInterests("nuôi lợn"))
        // Fine in conversation, only the pickers refuse it.
        XCTAssertEqual(v("tin tức về ma túy"), .clean)
    }

    func testLinks() {
        XCTAssertTrue(ModerationRules.containsLink("xem tại https://example.com/x"))
        XCTAssertTrue(ModerationRules.containsLink("nhắn t.me/abc123"))
        XCTAssertTrue(ModerationRules.containsLink("www.shop.vn"))
        XCTAssertFalse(ModerationRules.containsLink("mình ở quận 1, hẹn gặp"))
    }

    func testScamShapes() {
        XCTAssertTrue(ModerationRules.looksLikeScam("Chuyển khoản trước vào STK 0123456789 Vietcombank để giữ chỗ"))
        XCTAssertTrue(ModerationRules.looksLikeScam("Kiếm tiền online, lãi suất cao, hoa hồng mỗi ngày"))
        XCTAssertTrue(ModerationRules.looksLikeScam("Làm giàu nhanh tại https://bit.ly/abc, hoa hồng 30%"))
        XCTAssertFalse(ModerationRules.looksLikeScam("Mình bán lại cái ghế, 500k, nhận tiền mặt khi gặp"))
        XCTAssertFalse(ModerationRules.looksLikeScam("SĐT mình 0901234567 nhé"))
    }
}

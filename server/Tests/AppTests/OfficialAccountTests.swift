@testable import App
import XCTest

/// The official account keeps the least information (migration 104): only
/// its name and pictures change through PATCH /users/me.
final class OfficialAccountTests: XCTestCase {
    func testOnlyNameAndPicturesAreEditable() {
        let sent: Set<String> = ["display_name", "avatar_url", "cover_url", "mode", "bio", "ward_id",
                                 "dob", "job_title", "company", "interests", "skills", "languages",
                                 "hobby_theme", "work_theme"]
        XCTAssertEqual(OfficialAccount.editableProfileKeys(sent),
                       ["display_name", "avatar_url", "cover_url", "mode", "hobby_theme", "work_theme"])
    }

    func testNothingSentNothingKept() {
        XCTAssertTrue(OfficialAccount.editableProfileKeys([]).isEmpty)
        XCTAssertTrue(OfficialAccount.editableProfileKeys(["bio", "dob"]).isEmpty)
    }
}

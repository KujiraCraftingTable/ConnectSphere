@testable import App
import XCTest

/// Sign-up is refused unless the person ticked the current Terms and Privacy Policy.
final class ConsentTests: XCTestCase {
    func testOnlyTheCurrentVersionCounts() throws {
        XCTAssertNoThrow(try ConsentStore.requireCurrent(LegalDocs.version))
        XCTAssertThrowsError(try ConsentStore.requireCurrent(nil))
        XCTAssertThrowsError(try ConsentStore.requireCurrent(""))
        XCTAssertThrowsError(try ConsentStore.requireCurrent("2020-01-01"))
    }

    func testBothDocumentsAreRecorded() {
        XCTAssertEqual(Set(LegalDocs.documents), ["terms", "privacy"])
    }
}

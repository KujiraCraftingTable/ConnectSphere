@testable import App
import XCTest

/// A feed thumbnail that was never made falls back to its original.
final class UploadResolveTests: XCTestCase {
    func testThumbnailFallsBackToTheOriginal() {
        let files: Set<String> = ["A.jpg", "B.png", "B_t.jpg"]
        let exists = { files.contains($0) }
        XCTAssertEqual(UploadsController.resolve("A_t.jpg", exists: exists), "A.jpg")
        XCTAssertEqual(UploadsController.resolve("B_t.jpg", exists: exists), "B_t.jpg")
        XCTAssertEqual(UploadsController.resolve("A.jpg", exists: exists), "A.jpg")
        XCTAssertNil(UploadsController.resolve("C_t.jpg", exists: exists))
        XCTAssertNil(UploadsController.resolve("C.jpg", exists: exists))
    }
}

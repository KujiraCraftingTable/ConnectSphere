@testable import App
import XCTest

final class MediaPathTests: XCTestCase {
    private let ours: (String) -> Bool = { $0 == "/uploads/a.jpg" || $0 == "/uploads/messages/v.m4a" }

    func testOwnUploadLosesItsHost() {
        for link in ["http://localhost:3000/uploads/a.jpg", "http://Tris-MacBook-Pro.local:3000/uploads/a.jpg",
                     "http://192.168.68.62:3000/uploads/a.jpg", "https://api.example.app/uploads/a.jpg"] {
            XCTAssertEqual(MediaPath.storable(link, exists: ours), "/uploads/a.jpg", link)
        }
        XCTAssertEqual(MediaPath.storable("http://localhost:3000/uploads/messages/v.m4a?token=abc", exists: ours),
                       "/uploads/messages/v.m4a")
    }

    func testOtherLinksAreKept() {
        XCTAssertEqual(MediaPath.storable("/uploads/a.jpg", exists: ours), "/uploads/a.jpg")
        XCTAssertEqual(MediaPath.storable("https://i.ytimg.com/vi/x/hqdefault.jpg", exists: ours), "https://i.ytimg.com/vi/x/hqdefault.jpg")
        // Someone else's /uploads/ folder: not a file we hold.
        XCTAssertEqual(MediaPath.storable("https://other.site/uploads/b.jpg", exists: ours), "https://other.site/uploads/b.jpg")
        XCTAssertEqual(MediaPath.storable("http://localhost:3000/uploads/../secret", exists: { _ in true }),
                       "http://localhost:3000/uploads/../secret")
    }

    func testBlankBecomesNil() {
        XCTAssertNil(MediaPath.storable("  ", exists: ours))
        XCTAssertNil(MediaPath.storable(nil as String?, exists: ours))
        XCTAssertEqual(MediaPath.storable(["", "http://localhost:3000/uploads/a.jpg"], exists: ours), ["/uploads/a.jpg"])
    }
}

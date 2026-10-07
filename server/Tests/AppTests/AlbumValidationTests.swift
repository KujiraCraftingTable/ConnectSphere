import XCTest
import Vapor
@testable import App

final class AlbumValidationTests: XCTestCase {
    private func photos(_ n: Int) -> [MessageObject.MediaItem] {
        (0..<n).map { .init(url: "/uploads/messages/1730000000000-abcd\($0).jpg", type: "image") }
    }

    func testAlbumNeedsTwoToTenPhotos() throws {
        XCTAssertThrowsError(try MessagesController.validateAlbum(type: "album", items: nil))
        XCTAssertThrowsError(try MessagesController.validateAlbum(type: "album", items: photos(1)))
        XCTAssertThrowsError(try MessagesController.validateAlbum(type: "album", items: photos(11)))
        XCTAssertEqual(try MessagesController.validateAlbum(type: "album", items: photos(3))?.count, 3)
        XCTAssertEqual(try MessagesController.validateAlbum(type: "album", items: photos(10))?.count, 10)
    }

    func testAlbumOnlyAcceptsOurOwnUploadedPhotos() {
        for url in ["https://evil.example/x.jpg", "/uploads/../backend/.env", "/uploads/messages/../../x.jpg",
                    "/uploads/x.jpg", "/uploads/messages/clip.mp4", "/uploads/messages/.hidden.jpg"] {
            var items = photos(2)
            items[1].url = url
            XCTAssertThrowsError(try MessagesController.validateAlbum(type: "album", items: items), url)
        }
        var video = photos(2)
        video[0].type = "video"
        XCTAssertThrowsError(try MessagesController.validateAlbum(type: "album", items: video))
    }

    func testOtherTypesCannotSmuggleItems() throws {
        XCTAssertNil(try MessagesController.validateAlbum(type: "image", items: nil))
        XCTAssertThrowsError(try MessagesController.validateAlbum(type: "image", items: photos(2)))
    }
}

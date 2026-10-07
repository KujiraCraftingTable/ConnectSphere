import Foundation
import Testing
@testable import ConnectSphere

struct ChatAlbumTests {
    private func files(_ names: [String]) -> [URL] { names.map { URL(fileURLWithPath: "/tmp/\($0)") } }

    @Test func onePhotoIsSentAlone() {
        let plan = ChatViewModel.plan(mediaFiles: files(["a.jpg"]))
        #expect(plan.album.isEmpty)
        #expect(plan.singles.map(\.lastPathComponent) == ["a.jpg"])
    }

    @Test func severalPhotosBecomeOneAlbumAndVideosStaySeparate() {
        let plan = ChatViewModel.plan(mediaFiles: files(["a.jpg", "clip.mov", "b.heic", "c.png"]))
        #expect(plan.album.map(\.lastPathComponent) == ["a.jpg", "b.heic", "c.png"])
        #expect(plan.singles.map(\.lastPathComponent) == ["clip.mov"])
    }

    @Test func onePhotoPlusVideoIsNotAnAlbum() {
        let plan = ChatViewModel.plan(mediaFiles: files(["a.jpg", "clip.mp4"]))
        #expect(plan.album.isEmpty)
        #expect(plan.singles.count == 2)
    }

    @Test func albumIsCappedAtTenPhotos() {
        let plan = ChatViewModel.plan(mediaFiles: files((0..<12).map { "p\($0).jpg" }))
        #expect(plan.album.count == 10)
        #expect(plan.singles.map(\.lastPathComponent) == ["p10.jpg", "p11.jpg"])
    }

    @Test func albumMessageDecodesAndPreviews() throws {
        let json = """
        {"id":"m1","conversation_id":"c1","sender_id":"u1","content":null,"message_type":"album",
         "media_url":"/uploads/messages/a.jpg",
         "media_items":[{"url":"/uploads/messages/a.jpg","type":"image"},{"url":"/uploads/messages/b.jpg","type":"image"},
                        {"url":"/uploads/messages/c.jpg","type":"image"}],
         "created_at":"2026-10-08T09:00:00.000Z","is_deleted":false,"reactions":{}}
        """
        var message = try JSONDecoder.makeISO8601().decode(Message.self, from: Data(json.utf8))
        #expect(message.messageType == .album)
        #expect(message.mediaItems?.count == 3)
        #expect(message.albumURLs().count == 3)
        #expect(message.albumPreview.hasPrefix("📷 3"))
        message.content = "Trip photos"
        #expect(message.albumPreview == "📷 Trip photos")
        message.markDeleted()
        #expect(message.mediaItems == nil && message.albumURLs().isEmpty)
    }

    @Test func unknownCountReadsAsAlbum() {
        #expect(Message.albumPreview(caption: nil, count: nil).hasPrefix("📷 "))
        #expect(Message.albumPreview(caption: "", count: 4).contains("4"))
    }
}

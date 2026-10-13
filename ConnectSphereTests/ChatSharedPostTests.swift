import Foundation
import Testing
@testable import ConnectSphere

/// A post shared into a chat: the message keeps only the post's id (each
/// viewer loads the post themselves), and its previews say what it is.
struct ChatSharedPostTests {
    private func message(content: String?, postId: String?) throws -> Message {
        let json = """
        {"id":"m1","conversation_id":"c1","sender_id":"u1","content":\(content.map { "\"\($0)\"" } ?? "null"),
         "message_type":"post","shared_post_id":\(postId.map { "\"\($0)\"" } ?? "null"),
         "created_at":"2026-10-14T09:00:00.000Z","is_deleted":false,"reactions":{}}
        """
        return try JSONDecoder.makeISO8601().decode(Message.self, from: Data(json.utf8))
    }

    @Test func decodesTheSharedPost() throws {
        let m = try message(content: "look", postId: "p1")
        #expect(m.messageType == .post)
        #expect(m.sharedPostId == "p1")
    }

    /// Pinned, it previews as the note — or says it's a shared post.
    @Test func pinnedPreviewUsesTheNoteOrSaysItsAPost() throws {
        func pinned(_ content: String?) throws -> PinnedMessage {
            let json = """
            {"message_id":"m1","content":\(content.map { "\"\($0)\"" } ?? "null"),"message_type":"post",
             "sender_id":"u1","sender_name":"An","pinned_by":"u1","pinned_at":"2026-10-14T09:00:00.000Z"}
            """
            return try JSONDecoder.makeISO8601().decode(PinnedMessage.self, from: Data(json.utf8))
        }
        #expect(try pinned("look").preview == "📰 look")
        let bare = try pinned(nil).preview
        #expect(bare.hasPrefix("📰 ") && bare.count > 2)
    }

    /// A deleted post clears the link; the message still decodes.
    @Test func postDeletedSinceStillDecodes() throws {
        #expect(try message(content: nil, postId: nil).sharedPostId == nil)
    }
}

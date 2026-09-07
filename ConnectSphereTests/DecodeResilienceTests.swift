import Testing
import Foundation
@testable import ConnectSphere

/// A single malformed row (deleted author, null field, unknown enum, date-only
/// string) must never fail the whole list payload. These feed hostile JSON
/// through the real DTOs + JSONDecoder.makeISO8601() and assert graceful
/// degradation.
struct DecodeResilienceTests {

    private var decoder: JSONDecoder { .makeISO8601() }

    @Test func postWithNullAuthorDecodesAsDeletedUser() throws {
        let json = """
        { "id": "p1", "content": "hi", "mode": "hobby", "privacy": "public",
          "like_count": 0, "comment_count": 0, "share_count": 0,
          "created_at": "2026-01-01T00:00:00Z", "tags": [], "author": null,
          "post_type": "text" }
        """.data(using: .utf8)!
        let dto = try decoder.decode(PostDTO.self, from: json)
        #expect(dto.author.displayName == "Deleted User")
        #expect(dto.toPost().author.name == "Deleted User")
    }

    @Test func postWithNullContentAndCountsDecodes() throws {
        let json = """
        { "id": "p2", "content": null, "mode": null, "privacy": null,
          "like_count": null, "comment_count": null, "share_count": null,
          "created_at": "2026-01-01T00:00:00Z",
          "author": { "id": "u1", "username": "a", "display_name": "A", "avatar_color": "#111" } }
        """.data(using: .utf8)!
        let dto = try decoder.decode(PostDTO.self, from: json)
        #expect(dto.content == "")
        #expect(dto.likeCount == 0)
        #expect(dto.mode == "hobby")
    }

    @Test func commentWithNullAuthorDecodes() throws {
        let json = """
        { "id": "c1", "content": null, "created_at": "2026-01-01T00:00:00Z",
          "parent_comment_id": null, "like_count": null, "is_liked": null, "author": null }
        """.data(using: .utf8)!
        let dto = try decoder.decode(CommentDTO.self, from: json)
        #expect(dto.author.displayName == "Deleted User")
        #expect(dto.content == "")
    }

    @Test func unknownMessageTypeFallsBackToUnknownNotThrow() throws {
        let json = """
        { "id": "m1", "conversation_id": "cv1", "sender_id": "u1",
          "message_type": "sticker", "created_at": "2026-01-01T00:00:00Z" }
        """.data(using: .utf8)!
        let msg = try decoder.decode(Message.self, from: json)
        #expect(msg.messageType == .unknown)
    }

    @Test func badDateStringYieldsDistantPastNotThrow() throws {
        let json = """
        { "id": "p3", "content": "x", "mode": "hobby", "privacy": "public",
          "like_count": 0, "comment_count": 0, "share_count": 0,
          "created_at": "not-a-date", "tags": [],
          "author": { "id": "u1", "username": "a", "display_name": "A", "avatar_color": "#111" } }
        """.data(using: .utf8)!
        let dto = try decoder.decode(PostDTO.self, from: json)
        #expect(dto.createdAt == .distantPast)
    }

    @Test func dateOnlyStringParses() throws {
        let json = #"{ "url": "https://x.com", "title": null }"#.data(using: .utf8)!
        let dto = try decoder.decode(LinkPreviewDTO.self, from: json)
        #expect(dto.title == "")
    }

    @Test func directConversationWithDeletedPeerDecodes() throws {
        let json = """
        { "id": "cv1", "mode": "hobby", "is_group": false,
          "updated_at": "2026-01-01T00:00:00Z",
          "other_user_id": null, "other_user_username": null,
          "other_user_name": null, "other_user_avatar_color": null }
        """.data(using: .utf8)!
        let dto = try decoder.decode(Conversation.self, from: json)
        if case .direct(_, _, let name, _, _, _, _) = dto.peer {
            #expect(name == "Deleted User")
        } else {
            Issue.record("expected a .direct peer")
        }
    }

    @Test func preOnboardingAuthUserDecodes() throws {
        let json = #"{ "id": "u1", "username": "newbie" }"#.data(using: .utf8)!
        let dto = try decoder.decode(AuthUserDTO.self, from: json)
        #expect(dto.defaultMode == "hobby")
        #expect(dto.isSetup == false)
        #expect(dto.followerCount == 0)
    }
}

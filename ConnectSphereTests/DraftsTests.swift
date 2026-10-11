import Foundation
import Testing
@testable import ConnectSphere

@MainActor
struct DraftsTests {
    @Test func publishChoiceShapesTheRequest() {
        var now: [String: Any] = [:]
        PublishChoice.now.apply(to: &now, replacing: nil)
        #expect(now.isEmpty)                                   // posting is the default
        var draft: [String: Any] = [:]
        PublishChoice.draft.apply(to: &draft, replacing: "d1")
        #expect(draft["publish"] as? String == "draft" && draft["replaces_draft"] as? String == "d1")
        var fromDraft: [String: Any] = [:]
        PublishChoice.now.apply(to: &fromDraft, replacing: "d1")
        #expect(fromDraft["publish"] == nil && fromDraft["replaces_draft"] as? String == "d1")
    }

    @Test func aDraftsMediaComesBackAsUploadedItemsWithTheirAltText() {
        let media = PickedPostMedia.remote(["http://x/a.jpg", "http://x/b.mov"], alts: ["a dog"])
        #expect(media.map(\.remoteURL) == ["http://x/a.jpg", "http://x/b.mov"])
        #expect(media.map(\.altText) == ["a dog", ""])
        #expect(media.map(\.isVideo) == [false, true])
        #expect(media.allSatisfy { $0.image == nil && $0.pickerItem == nil })
    }

    private func post(_ extra: String) throws -> Post {
        let json = """
            {"id":"p1","content":"","mode":"work","privacy":"public","created_at":"2026-10-13T09:00:00.000Z",
             "like_count":0,"comment_count":0,"share_count":0,"post_type":"text","is_liked":false,"is_saved":false,
             "tags":[],"author":{"id":"u1","username":"a","display_name":"A","avatar_color":"#111111"}\(extra)}
            """
        return try JSONDecoder.makeISO8601().decode(PostDTO.self, from: Data(json.utf8)).toPost()
    }

    @Test func draftsDecodeTheirStatus() throws {
        let draft = try post(#","status":"draft","image_urls":["http://x/a.jpg","http://x/b.jpg"]"#)
        #expect(draft.publishStatus == "draft")
        #expect(draft.draftSnippet == "Photos")
        #expect(try post("").publishStatus == nil)              // published posts carry none
        let scheduled = try post(#","status":"scheduled","publish_at":"2026-10-20T02:00:00.000Z""#)
        #expect(scheduled.publishStatus == "scheduled" && scheduled.publishAt != nil)
    }
}

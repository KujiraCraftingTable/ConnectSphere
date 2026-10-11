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

    @Test func schedulingSendsTheTime() throws {
        let at = Date(timeIntervalSince1970: 1_800_003_600)
        var body: [String: Any] = [:]
        PublishChoice.schedule(at).apply(to: &body, replacing: "d1")
        #expect(body["publish"] as? String == "schedule")
        #expect((body["publish_at"] as? String).flatMap(ISO8601DateFormatter().date(from:)) == at)
        #expect(body["replaces_draft"] as? String == "d1")
        #expect(!PublishChoice.schedule(at).isLive)
    }

    @Test func thePickerStaysInsideTheServersWindow() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)    // a whole hour, UTC
        let range = ScheduleWindow.range(from: now)
        #expect(range.lowerBound > now.addingTimeInterval(5 * 60))
        #expect(range.upperBound < now.addingTimeInterval(180 * 86_400))
        let suggested = ScheduleWindow.suggested(from: now.addingTimeInterval(10 * 60))
        #expect(suggested >= now.addingTimeInterval(70 * 60))  // at least an hour away…
        #expect(Calendar.current.component(.minute, from: suggested) == 0)   // …on the hour
        #expect(range.contains(ScheduleWindow.suggested(from: now)))
    }
}

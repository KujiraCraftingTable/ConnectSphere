import Foundation
import Testing
@testable import ConnectSphere

struct CommunityTests {
    private func decode(_ extra: String) throws -> Community {
        let json = """
        {"id":"c1","name":"Pokemon TCG VN","description":"Trade cards","type":"fandom","privacy":"public",
         "icon_emoji":"🃏","avatar_url":null,"cover_color":"#7F5AF0","member_count":12,"post_count":3,
         "created_at":"2026-10-01T10:00:00.000Z"\(extra)}
        """
        return try JSONDecoder.makeISO8601().decode(CommunityDTO.self, from: Data(json.utf8)).toCommunity()
    }

    @Test func decodesCoverPinApprovalAndNotifyLevel() throws {
        let c = try decode(#","cover_url":"/uploads/c.jpg","is_pinned":true,"require_post_approval":true,"notify_level":"all","is_member":true"#)
        #expect(c.coverUrl == "/uploads/c.jpg")
        #expect(c.isPinned && c.requirePostApproval && c.isMember)
        #expect(c.notifyLevel == .all)
    }

    @Test func olderResponsesStillDecodeWithDefaults() throws {
        let c = try decode("")
        #expect(c.coverUrl == nil && !c.isPinned && !c.requirePostApproval)
        #expect(c.notifyLevel == nil && !c.isMember)
    }
}

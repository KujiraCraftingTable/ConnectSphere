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

    @Test func myContentDecodesPostsWithStatusAndReason() throws {
        let json = """
        {"counts":{"published":2,"pending":1,"declined":1,"comments":3},
         "posts":[{"id":"p1","content":"held","mode":"hobby","privacy":"public","like_count":0,"comment_count":0,
                   "share_count":0,"created_at":"2026-10-25T10:00:00.000Z","post_type":"text","is_pinned":false,
                   "is_liked":false,"is_saved":false,"tags":[],"status":"declined","decline_reason":"Off topic",
                   "author":{"id":"u1","username":"a","display_name":"A","avatar_color":"#123456"}}],
         "comments":[]}
        """
        let content = try JSONDecoder.makeISO8601().decode(MyCommunityContent.self, from: Data(json.utf8))
        #expect(content.counts == .init(published: 2, pending: 1, declined: 1, comments: 3))
        #expect(content.posts.first?.publishStatus == "declined")
        #expect(content.posts.first?.declineReason == "Off topic")
    }

    @MainActor @Test func pendingIsCountedEvenAtZero() {
        let vm = ManageCommunityContentViewModel(communityId: "c1")
        #expect(vm.count(of: .pending) == 0)
        #expect(vm.count(of: .all) == 0)
        #expect(MyCommunityContent.Status.allCases.contains(.pending))
    }
}

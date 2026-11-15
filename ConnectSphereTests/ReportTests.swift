import Foundation
import Testing
@testable import ConnectSphere

/// Reporting (server migration 089): the reasons offered must match what the
/// server accepts for each kind of content, or a report is refused.
struct ReportTests {
    @Test func reasonsDependOnWhatIsReported() {
        #expect(ReportTargetType.post.reasons.contains(.offTopic))
        #expect(!ReportTargetType.message.reasons.contains(.offTopic))
        #expect(!ReportTargetType.post.reasons.contains(.underage))
        #expect(!ReportTargetType.user.reasons.contains(.underage))
        #expect(ReportTargetType.user.reasons.contains(.impersonation))
        #expect(!ReportTargetType.comment.reasons.contains(.impersonation))
    }

    @Test func everyTargetOffersTheSeriousReasons() {
        for t in [ReportTargetType.post, .comment, .message, .user, .community, .story, .company] {
            #expect(t.reasons.contains(.childSafety))
            #expect(t.reasons.contains(.selfHarm))
        }
    }

    @Test func communityReportsKeepTheirOldReasonNames() {
        #expect(ModerationReason.hate.communityValue == "hate_speech")
        #expect(ModerationReason(communityValue: "hate_speech") == .hate)
        #expect(ModerationReason(communityValue: "off_topic") == .offTopic)
        #expect(ModerationReason.communityMember.allSatisfy { ModerationReason(communityValue: $0.communityValue) == $0 })
    }

    @Test func subjectsHaveStableIdentity() {
        #expect(ReportSubject.content(.post, id: "a").id != ReportSubject.content(.comment, id: "a").id)
        #expect(ReportSubject.communityMember(communityId: "c", userId: "u").reasons == ModerationReason.communityMember)
    }
}

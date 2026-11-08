import Foundation
import Testing
@testable import ConnectSphere

/// Moderation screens decode what the server really sends: these bodies were
/// captured from a local server (migration 089) after a report, a decision
/// and an appeal.
struct ModerationDecodingTests {
    private struct Box<T: Decodable>: Decodable { let data: T }
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder.makeISO8601().decode(Box<T>.self, from: Data(json.utf8)).data
    }

    @Test func queueListDecodes() throws {
        let cases = try decode([ModerationCase].self, Self.cases)
        let c = try #require(cases.first)
        #expect(c.policy == "scam")
        #expect(c.severity == 1)
        #expect(c.author?.username == "mia_cofounder")
        #expect(c.snapshot.text?.isEmpty == false)
        #expect(c.snapshot.images.isEmpty)
    }

    @Test func caseDetailDecodes() throws {
        let d = try decode(ModerationCaseDetail.self, Self.detail)
        #expect(d.case.decision == "remove_strike")
        #expect(d.reports.first?.detail == "asks for bank transfer")
        #expect(d.appeal?.status == "pending")
        #expect(d.decisionNote == "fixture")
        #expect(d.actions.map(\.action).contains("decided"))
    }

    @Test func appealsDecode() throws {
        let items = try decode([ModerationAppealItem].self, Self.appeals)
        #expect(items.first?.appeal.message == "please look again")
    }

    @Test func accountStatusDecodesForAuthorAndReporter() throws {
        let author = try decode(AccountStatus.self, Self.statusAuthor)
        #expect(!author.isStaff)
        #expect(author.strikes.count == 1)
        #expect(author.decisions.first?.appealStatus == "pending")
        #expect(author.decisions.first?.canAppeal == false)
        let reporter = try decode(AccountStatus.self, Self.statusReporter)
        #expect(reporter.isStaff)
        #expect(reporter.reports.first?.outcome == "removed")
    }

    @Test func snapshotOfAMessageKeepsEarlierLines() throws {
        let json = #"{"message":{"type":"text","content":"send money","media_url":null},"earlier":[{"type":"text","content":"hi"}],"photos":7}"#
        let s = try JSONDecoder().decode(CaseSnapshot.self, from: Data(json.utf8))
        #expect(s.text == "send money")
        #expect(s.earlier.count == 1)
        #expect(s.images.isEmpty)   // a field of the wrong type is skipped, not fatal
    }

    @Test func overdueAfterADay() {
        let now = Date()
        #expect(ModerationQueueViewModel.isOverdue(now.addingTimeInterval(-25 * 3600), now: now))
        #expect(!ModerationQueueViewModel.isOverdue(now.addingTimeInterval(-3600), now: now))
    }

    @Test func suspensionNeedsTheExactServerMessage() async {
        var fired = 0
        let token = NotificationCenter.default.addObserver(forName: .accountSuspended, object: nil, queue: nil) { _ in fired += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        AccountSuspension.check(statusCode: 403, message: "Forbidden")
        AccountSuspension.check(statusCode: 401, message: AccountSuspension.serverMessage)
        AccountSuspension.check(statusCode: 403, message: AccountSuspension.serverMessage)
        await MainActor.run {}
        try? await Task.sleep(for: .milliseconds(50))
        #expect(fired == 1)
    }

    static let cases = #"{"data": [{"mode": "work", "target_id": "e68615b2-be35-4b26-8f9e-f0f066b8d5a7", "status": "open", "decided_at": null, "report_count": 1, "author": {"banned_at": null, "id": "046580f2-b771-42f9-a87a-18ab489b7a98", "restricted_until": null, "past_cases": 0, "username": "mia_cofounder", "active_strikes": 0}, "decision": null, "source": "report", "severity": 1, "policy": "scam", "target_type": "post", "community_id": null, "created_at": "2026-11-04T13:59:24.473Z", "snapshot": {"article_title": null, "image_urls": null, "post_type": "text", "created_at": "2026-09-19T03:38:08.22056+00:00", "link_url": null, "content": "Edtech founders in Vietnam: let's start a monthly coffee meetup in Hanoi to share what's working and what isn't. Comment if you're in."}, "id": "2a796a4a-5cc6-4d68-aff0-78385551f4e5", "auto_hidden": false}]}"#

    static let detail = #"{"data": {"case": {"created_at": "2026-11-04T13:59:24.473Z", "author": {"banned_at": null, "past_cases": 0, "active_strikes": 1, "username": "mia_cofounder", "id": "046580f2-b771-42f9-a87a-18ab489b7a98", "restricted_until": null}, "snapshot": {"link_url": null, "content": "Edtech founders in Vietnam: let's start a monthly coffee meetup in Hanoi to share what's working and what isn't. Comment if you're in.", "article_title": null, "image_urls": null, "post_type": "text", "created_at": "2026-09-19T03:38:08.22056+00:00"}, "status": "actioned", "decided_at": "2026-11-04T13:59:24.621Z", "mode": "work", "decision": "remove_strike", "severity": 1, "target_type": "post", "source": "report", "target_id": "e68615b2-be35-4b26-8f9e-f0f066b8d5a7", "report_count": 1, "policy": "scam", "auto_hidden": false, "id": "2a796a4a-5cc6-4d68-aff0-78385551f4e5", "community_id": null}, "actions": [{"detail": {"source": "report", "policy": "scam"}, "actor_username": null, "action": "case_opened", "created_at": "2026-11-04T13:59:24.485Z"}, {"detail": {"decision": "remove_strike"}, "actor_username": "naytestmowo", "action": "decided", "created_at": "2026-11-04T13:59:24.621Z"}, {"detail": {}, "actor_username": "mia_cofounder", "action": "appeal_filed", "created_at": "2026-11-04T13:59:24.665Z"}], "appeal": {"status": "pending", "created_at": "2026-11-04T13:59:24.663Z", "case_id": "2a796a4a-5cc6-4d68-aff0-78385551f4e5", "decided_at": null, "id": "c6acdc6e-6a83-44e1-8714-45e99ac9850b", "message": "please look again"}, "decision_note": "fixture", "reports": [{"reason": "scam", "detail": "asks for bank transfer", "reporter_username": "naytestmowo", "id": "c914db31-3556-4851-8d9c-5d58b7f008b6", "created_at": "2026-11-04T13:59:24.473Z"}]}}"#

    static let appeals = #"{"data": [{"appeal": {"status": "pending", "case_id": "2a796a4a-5cc6-4d68-aff0-78385551f4e5", "created_at": "2026-11-04T13:59:24.663Z", "decided_at": null, "message": "please look again", "id": "c6acdc6e-6a83-44e1-8714-45e99ac9850b"}, "case": {"target_id": "e68615b2-be35-4b26-8f9e-f0f066b8d5a7", "created_at": "2026-11-04T13:59:24.473Z", "author": {"past_cases": 0, "active_strikes": 1, "username": "mia_cofounder", "banned_at": null, "restricted_until": null, "id": "046580f2-b771-42f9-a87a-18ab489b7a98"}, "mode": "work", "community_id": null, "decided_at": "2026-11-04T13:59:24.621Z", "snapshot": {"created_at": "2026-09-19T03:38:08.22056+00:00", "content": "Edtech founders in Vietnam: let's start a monthly coffee meetup in Hanoi to share what's working and what isn't. Comment if you're in.", "post_type": "text", "image_urls": null, "article_title": null, "link_url": null}, "severity": 1, "id": "2a796a4a-5cc6-4d68-aff0-78385551f4e5", "report_count": 1, "source": "report", "status": "actioned", "target_type": "post", "auto_hidden": false, "decision": "remove_strike", "policy": "scam"}}]}"#

    static let statusAuthor = #"{"data": {"app_role": "user", "restricted_until": null, "reports": [], "ban_reason": null, "banned_at": null, "decisions": [{"can_appeal": false, "case_id": "2a796a4a-5cc6-4d68-aff0-78385551f4e5", "decided_at": "2026-11-04T13:59:24.621Z", "snapshot": {"article_title": null, "image_urls": null, "content": "Edtech founders in Vietnam: let's start a monthly coffee meetup in Hanoi to share what's working and what isn't. Comment if you're in.", "link_url": null, "post_type": "text", "created_at": "2026-09-19T03:38:08.22056+00:00"}, "policy": "scam", "decision": "remove_strike", "target_type": "post", "appeal_status": "pending"}], "strikes": [{"created_at": "2026-11-04T13:59:24.621Z", "policy": "scam", "expires_at": "2027-02-02T13:59:24.621Z"}]}}"#

    static let statusReporter = #"{"data": {"app_role": "admin", "restricted_until": null, "reports": [{"outcome": "removed", "target_type": "post", "created_at": "2026-11-04T13:59:24.473Z", "reason": "scam"}], "ban_reason": null, "banned_at": null, "decisions": [], "strikes": []}}"#
}

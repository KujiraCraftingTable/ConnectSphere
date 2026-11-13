import Foundation

/// What can be reported app-wide (server `ReportTarget`, migration 089).
enum ReportTargetType: String {
    case post, comment, message, user, community, story, company

    private static let common: [ModerationReason] = [
        .spam, .scam, .harassment, .hate, .nuditySexual, .childSafety,
        .violence, .selfHarm, .illegalGoods, .misinformation, .other,
    ]

    /// Mirrors the server's list; a reason not offered here is refused there.
    var reasons: [ModerationReason] {
        switch self {
        case .post: Self.common + [.offTopic]
        case .comment, .message, .story: Self.common
        case .user, .community, .company: Self.common + [.impersonation]        }
    }

    /// Localization key for the sheet's title.
    var sheetTitle: String {
        switch self {
        case .post: "Report post"
        case .comment: "Report comment"
        case .message: "Report message"
        case .user: "Report profile"
        case .community: "Report community"
        case .story: "Report story"
        case .company: "Report page"        }
    }
}

/// The shared policy list (server `ModerationPolicy`).
enum ModerationReason: String, CaseIterable {
    case childSafety = "child_safety"
    case nuditySexual = "nudity_sexual"
    case violence
    case selfHarm = "self_harm"
    case scam, hate, harassment, spam
    case illegalGoods = "illegal_goods"
    case impersonation, underage, misinformation
    case offTopic = "off_topic"
    case other

    /// `community_reports` predates the shared list and says `hate_speech`.
    init?(communityValue: String) {
        self.init(rawValue: communityValue == "hate_speech" ? "hate" : communityValue)
    }

    /// The reasons a community's own staff judge for a member.
    static let communityMember: [ModerationReason] = [.spam, .harassment, .hate, .misinformation, .offTopic, .other]

    /// What `community_reports.reason` accepts for this reason.
    var communityValue: String { self == .hate ? "hate_speech" : rawValue }

    /// Localization key — callers wrap it in `bundle.loc(...)`.
    var displayName: String {
        switch self {
        case .childSafety: "Child sexual exploitation"
        case .nuditySexual: "Nudity or sexual content"
        case .violence: "Violence or threats"
        case .selfHarm: "Suicide or self-harm"
        case .scam: "Scam or fraud"
        case .hate: "Hate speech"
        case .harassment: "Harassment or bullying"
        case .spam: "Spam"
        case .illegalGoods: "Selling illegal or regulated goods"
        case .impersonation: "Pretending to be someone else"
        case .underage: "Under 16"
        case .misinformation: "False information"
        case .offTopic: "Off topic"
        case .other: "Something else"
        }
    }
}

/// Who or what a report sheet is about.
enum ReportSubject: Identifiable, Hashable {
    /// App-wide report, reviewed by the app's moderators. `mode` (hobby/work)
    /// only for a `user` report.
    case content(ReportTargetType, id: String, mode: String? = nil)
    /// A member of a community, reviewed by that community's own staff.
    case communityMember(communityId: String, userId: String)

    var id: String {
        switch self {
        case .content(let t, let id, _): "\(t.rawValue):\(id)"
        case .communityMember(let c, let u): "member:\(c):\(u)"
        }
    }

    var reasons: [ModerationReason] {
        switch self {
        case .content(let t, _, _): t.reasons
        case .communityMember: ModerationReason.communityMember
        }
    }

    var sheetTitle: String {
        switch self {
        case .content(let t, _, _): t.sheetTitle
        case .communityMember: "Report member"
        }
    }
}

/// `POST /api/reports` (and the community member route) — HTTP only.
struct ReportRepository {
    private let client = NetworkClient.shared

    func submit(_ subject: ReportSubject, reason: ModerationReason, detail: String?) async throws {
        guard let token = KeychainHelper.load(forKey: KeychainHelper.tokenKey) else {
            throw APIError.serverError(statusCode: 401, message: "Not authenticated")
        }
        struct Received: Decodable {}
        var body: [String: Any] = [:]
        let path: String
        switch subject {
        case .content(let type, let id, let mode):
            path = "/reports"
            body = ["target_type": type.rawValue, "target_id": id, "reason": reason.rawValue]
            if let mode { body["mode"] = mode }
        case .communityMember(let communityId, let userId):
            path = "/communities/\(communityId)/members/\(userId)/report"
            body = ["reason": reason.communityValue]
        }
        if let detail { body["detail"] = detail }
        _ = try await client.fetch(Received.self, path: path, method: "POST", token: token,
                                   bodyData: try JSONSerialization.data(withJSONObject: body))
    }
}

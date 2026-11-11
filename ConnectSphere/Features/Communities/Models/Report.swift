import Foundation

/// One reported post or member in a community's Reports screen: every report
/// on it, grouped. Reporters stay anonymous to community staff.
struct CommunityReportCase: Identifiable, Decodable, Hashable {
    struct ReasonCount: Decodable, Hashable { let reason: String; let count: Int }

    var id: String { targetId }
    let targetType: String
    let targetId: String
    let reportCount: Int
    let reasons: [ReasonCount]
    let latestAt: Date
    /// pending, resolved or dismissed.
    let status: String
    let postContent: String?
    let postImage: String?
    /// The post's author, or the reported member.
    let personId: String?
    let personName: String?
    let personUsername: String?
    let personAvatarUrl: String?
    let personAvatarColor: String?
    /// Earlier removals and warnings of this person in this community.
    let priorActions: Int

    var isPost: Bool { targetType == "post" }

    enum CodingKeys: String, CodingKey {
        case reasons, status
        case targetType = "target_type", targetId = "target_id", reportCount = "report_count"
        case latestAt = "latest_at", postContent = "post_content", postImage = "post_image"
        case personId = "person_id", personName = "person_name", personUsername = "person_username"
        case personAvatarUrl = "person_avatar_url", personAvatarColor = "person_avatar_color"
        case priorActions = "prior_actions"
    }
}

struct CommunityReportQueue: Decodable {
    let cases: [CommunityReportCase]
    let pendingCount: Int
}

/// A case opened from the Reports list: each report's reason and details, and
/// what staff have done about this post or person here before.
struct CommunityReportDetail: Decodable {
    struct Entry: Decodable, Identifiable {
        var id: String { "\(reason)-\(createdAt.timeIntervalSince1970)" }
        let reason: String
        let detail: String?
        let status: String
        let createdAt: Date
        enum CodingKeys: String, CodingKey { case reason, detail, status; case createdAt = "created_at" }
    }
    /// The admin or moderator who approved the post into the community, so the
    /// team can see who let content through when it turns out to break the rules.
    struct Approver: Decodable {
        let id: String
        let displayName: String
        let username: String
        let avatarUrl: String?
        let avatarColor: String?
        let approvedAt: Date
        enum CodingKeys: String, CodingKey {
            case id, username
            case displayName = "display_name", avatarUrl = "avatar_url"
            case avatarColor = "avatar_color", approvedAt = "approved_at"
        }
    }
    let summary: CommunityReportCase
    let reports: [Entry]
    /// nil when the post went live without needing approval.
    let approvedBy: Approver?
    /// False when you reported this yourself: another moderator or the admin decides it.
    let canDecide: Bool

    enum CodingKeys: String, CodingKey { case summary, reports; case approvedBy = "approved_by"; case canDecide = "can_decide" }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        summary = try c.decode(CommunityReportCase.self, forKey: .summary)
        reports = try c.decode([Entry].self, forKey: .reports)
        approvedBy = try c.decodeIfPresent(Approver.self, forKey: .approvedBy)
        canDecide = try c.decodeIfPresent(Bool.self, forKey: .canDecide) ?? true
    }
}

/// What staff can do with a case. Banning is the admin's alone.
enum CommunityReportDecision: String, CaseIterable, Identifiable {
    case keep, remove
    case removeWarn = "remove_warn"
    case removeBan = "remove_ban"
    case ban
    var id: String { rawValue }

    static func choices(isPost: Bool, isAdmin: Bool) -> [CommunityReportDecision] {
        let all: [CommunityReportDecision] = isPost ? [.keep, .remove, .removeWarn, .removeBan] : [.keep, .ban]
        return all.filter { isAdmin || !$0.isAdminOnly }
    }
    var isAdminOnly: Bool { self == .removeBan || self == .ban }
    var isDestructive: Bool { self != .keep }
}

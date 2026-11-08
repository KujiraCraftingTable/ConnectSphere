import Foundation

/// A copy of reported content as it was when the case opened (server
/// `moderation_cases.snapshot`). Its shape depends on what was reported, so
/// every field is optional and a field of an unexpected type is skipped.
struct CaseSnapshot: Decodable, Hashable {
    struct ChatLine: Decodable, Hashable {
        let type: String?
        let content: String?
        let mediaUrl: String?
        enum CodingKeys: String, CodingKey { case type, content, mediaUrl = "media_url" }
    }

    let content: String?
    let articleTitle: String?
    let username: String?
    let displayName: String?
    let name: String?
    let bio: String?
    let description: String?
    let about: String?
    let images: [String]
    let message: ChatLine?
    let earlier: [ChatLine]

    enum CodingKeys: String, CodingKey {
        case content, username, name, bio, description, about, message, earlier, photos
        case articleTitle = "article_title", displayName = "display_name"
        case imageUrls = "image_urls", imageUrl = "image_url", avatarUrl = "avatar_url"
        case coverUrl = "cover_url", logoUrl = "logo_url"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func s(_ k: CodingKeys) -> String? { (try? c.decodeIfPresent(String.self, forKey: k)) ?? nil }
        func list(_ k: CodingKeys) -> [String] { ((try? c.decodeIfPresent([String].self, forKey: k)) ?? nil) ?? [] }
        content = s(.content); articleTitle = s(.articleTitle); username = s(.username)
        displayName = s(.displayName); name = s(.name); bio = s(.bio)
        description = s(.description); about = s(.about)
        message = (try? c.decodeIfPresent(ChatLine.self, forKey: .message)) ?? nil
        earlier = ((try? c.decodeIfPresent([ChatLine].self, forKey: .earlier)) ?? nil) ?? []
        images = list(.imageUrls) + [s(.imageUrl), s(.avatarUrl), s(.coverUrl), s(.logoUrl)].compactMap { $0 }
            + list(.photos) + [message?.mediaUrl].compactMap { $0 }
    }

    /// The text that was reported, whichever field holds it.
    var text: String? {
        [message?.content, content, bio, description, about].compactMap { $0 }.first { !$0.isEmpty }
    }

    /// Who or what it is, for a profile, community or page.
    var title: String? { articleTitle ?? displayName ?? name }
}

/// Settings › Account status (`GET /api/account-status`).
struct AccountStatus: Decodable {
    /// A warning: three active in one mode within 90 days is a ban.
    struct Strike: Decodable, Hashable {
        let policy: String
        let createdAt: Date
        let expiresAt: Date
        let mode: String?
        let caseId: String?
        let targetType: String?
        let snapshot: CaseSnapshot?
        enum CodingKeys: String, CodingKey {
            case policy, mode, snapshot
            case createdAt = "created_at", expiresAt = "expires_at", caseId = "case_id", targetType = "target_type"
        }
    }
    /// An active ban in one mode (migration 106); no `bannedUntil` = permanent.
    struct Ban: Decodable, Hashable {
        let mode: String
        let bannedAt: Date
        let bannedUntil: Date?
        let policy: String?
        let note: String?
        let caseId: String?
        let targetType: String?
        let snapshot: CaseSnapshot?
        enum CodingKeys: String, CodingKey {
            case mode, policy, note, snapshot
            case bannedAt = "banned_at", bannedUntil = "banned_until", caseId = "case_id", targetType = "target_type"
        }
    }
    struct Decision: Decodable, Identifiable {
        let caseId: String
        let targetType: String
        let policy: String
        let decision: String
        let decidedAt: Date
        let snapshot: CaseSnapshot
        let appealStatus: String?
        let canAppeal: Bool
        var id: String { caseId }
        enum CodingKeys: String, CodingKey {
            case policy, decision, snapshot
            case caseId = "case_id", targetType = "target_type", decidedAt = "decided_at"
            case appealStatus = "appeal_status", canAppeal = "can_appeal"
        }
    }
    struct MyReport: Decodable, Hashable {
        let targetType: String
        let reason: String
        let createdAt: Date
        /// pending, removed or kept.
        let outcome: String
        enum CodingKeys: String, CodingKey {
            case reason, outcome, targetType = "target_type", createdAt = "created_at"
        }
    }

    let appRole: String
    let restrictedUntil: Date?
    let bannedAt: Date?
    let banReason: String?
    let strikes: [Strike]
    /// Older servers leave it out.
    let bans: [Ban]?
    let decisions: [Decision]
    let reports: [MyReport]

    /// The active ban in `mode`, if any.
    func ban(in mode: String) -> Ban? { bans?.first { $0.mode == mode } }
    /// Active warnings in `mode`; ones from before modes count in both.
    func warnings(in mode: String) -> [Strike] { strikes.filter { $0.mode == nil || $0.mode == mode } }

    var isStaff: Bool { appRole == "moderator" || appRole == "admin" }
    /// The official @connectsphere account, the only admin (server migration 104).
    var isAdmin: Bool { appRole == "admin" }

    enum CodingKeys: String, CodingKey {
        case strikes, bans, decisions, reports
        case appRole = "app_role", restrictedUntil = "restricted_until", bannedAt = "banned_at", banReason = "ban_reason"
    }
}

/// One item in the admin review queue.
struct ModerationCase: Decodable, Identifiable, Hashable {
    struct Author: Decodable, Hashable {
        let id: String
        let username: String
        let bannedAt: Date?
        let restrictedUntil: Date?
        let activeStrikes: Int
        let pastCases: Int
        enum CodingKeys: String, CodingKey {
            case id, username, bannedAt = "banned_at", restrictedUntil = "restricted_until"
            case activeStrikes = "active_strikes", pastCases = "past_cases"
        }
    }

    let id: String
    let targetType: String
    let source: String
    let policy: String
    let severity: Int
    let reportCount: Int
    let status: String
    let autoHidden: Bool
    let decision: String?
    let createdAt: Date
    let author: Author?
    let snapshot: CaseSnapshot
    /// The reported item, and the post to open it in (a comment's post).
    let targetId: String?
    let postId: String?

    enum CodingKeys: String, CodingKey {
        case id, source, policy, severity, status, decision, author, snapshot
        case targetType = "target_type", reportCount = "report_count", autoHidden = "auto_hidden", createdAt = "created_at"
        case targetId = "target_id", postId = "post_id"
    }
}

struct ModerationCaseDetail: Decodable {
    struct Report: Decodable, Identifiable {
        let id: String
        let reason: String
        let detail: String?
        let reporterUsername: String
        let createdAt: Date
        enum CodingKeys: String, CodingKey {
            case id, reason, detail, reporterUsername = "reporter_username", createdAt = "created_at"
        }
    }
    struct Action: Decodable, Hashable {
        let action: String
        let actorUsername: String?
        let detail: [String: String]
        let createdAt: Date
        enum CodingKeys: String, CodingKey {
            case action, detail, actorUsername = "actor_username", createdAt = "created_at"
        }
    }

    let `case`: ModerationCase
    let reports: [Report]
    let actions: [Action]
    let appeal: ModerationAppeal?
    let decisionNote: String?

    enum CodingKeys: String, CodingKey { case `case`, reports, actions, appeal, decisionNote = "decision_note" }
}

struct ModerationAppeal: Decodable, Identifiable, Hashable {
    let id: String
    let caseId: String
    let message: String?
    let status: String
    let createdAt: Date
    enum CodingKeys: String, CodingKey { case id, message, status, caseId = "case_id", createdAt = "created_at" }
}

struct ModerationAppealItem: Decodable, Identifiable {
    let appeal: ModerationAppeal
    let `case`: ModerationCase
    var id: String { appeal.id }
}

/// What an admin can decide on a case (server `ModerationDecision`).
enum ModerationDecisionKind: String, CaseIterable {
    case keep, remove
    case removeStrike = "remove_strike"
    case restrict, ban

    /// Localization key.
    var label: String {
        switch self {
        case .keep: "Keep — doesn't break the rules"
        case .remove: "Remove"
        case .removeStrike: "Remove and give a strike"
        case .restrict: "Restrict the account"
        case .ban: "Ban the account"
        }
    }

    /// Localization key for what the author was told.
    var outcome: String {
        switch self {
        case .keep: "Kept"
        case .remove: "Removed"
        case .removeStrike: "Removed, with a strike"
        case .restrict: "Removed and restricted"
        case .ban: "Account banned"
        }
    }
}

extension String {
    /// "post" → "Post": a localization key for a reported kind of content.
    var reportTargetLabel: String {
        switch self {
        case "post": "Post"
        case "comment": "Comment"
        case "message": "Message"
        case "user": "Profile"
        case "community": "Community"
        case "story": "Story"
        case "company": "Company page"
        case "dating_profile": "Dating profile"
        default: self
        }
    }

    /// A policy key ("nudity_sexual") → its localization key.
    var policyLabel: String { ModerationReason(rawValue: self)?.displayName ?? self }
}

// MARK: - Admin tools (the official account only)

/// `GET /api/admin/stats`. Hobby and Work are counted apart.
struct AdminStats: Decodable {
    struct ModeCounts: Decodable { let hobby: Int; let work: Int }
    let accounts: Int
    let newAccounts7d: Int
    let profiles: ModeCounts
    let posts: ModeCounts
    let posts7d: ModeCounts
    let openCases: Int
    let pendingAppeals: Int
    let reports7d: Int

    enum CodingKeys: String, CodingKey {
        case accounts, profiles, posts
        case newAccounts7d = "new_accounts_7d", posts7d = "posts_7d", openCases = "open_cases"
        case pendingAppeals = "pending_appeals", reports7d = "reports_7d"
    }
}

/// `GET /api/admin/users/lookup`: no email, phone or birthday.
struct AdminUserLookup: Decodable {
    let id: String
    let username: String
    let hobbyDisplayName: String?
    let workDisplayName: String?
    let appRole: String
    let createdAt: Date
    let deletedAt: Date?
    let bannedAt: Date?
    let restrictedUntil: Date?
    let activeStrikes: Int
    let posts: Int
    let openCases: Int

    enum CodingKeys: String, CodingKey {
        case id, username, posts
        case hobbyDisplayName = "hobby_display_name", workDisplayName = "work_display_name"
        case appRole = "app_role", createdAt = "created_at", deletedAt = "deleted_at", bannedAt = "banned_at"
        case restrictedUntil = "restricted_until", activeStrikes = "active_strikes", openCases = "open_cases"
    }
}

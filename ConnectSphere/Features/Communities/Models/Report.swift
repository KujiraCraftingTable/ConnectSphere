import Foundation

/// A moderation queue item (report + target details)
struct ModerationItem: Identifiable, Decodable {
    let id: String
    let targetType: String
    let targetId: String
    let reason: String
    let detail: String?
    let status: String
    let createdAt: Date
    let postContent: String?
    let memberInfo: ModerationMemberInfo?

    enum CodingKeys: String, CodingKey {
        case id, status, reason, detail
        case targetType  = "target_type"
        case targetId    = "target_id"
        case createdAt   = "created_at"
        case postContent = "post_content"
        case memberInfo  = "member_info"
    }
}

/// Minimal member info embedded in a moderation item
struct ModerationMemberInfo: Decodable {
    let id: String
    let username: String
    let displayName: String
    let avatarColor: String

    enum CodingKeys: String, CodingKey {
        case id, username
        case displayName = "display_name"
        case avatarColor = "avatar_color"
    }
}

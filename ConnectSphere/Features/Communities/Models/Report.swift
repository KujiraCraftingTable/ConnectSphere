import Foundation

/// Reasons a user can select when submitting a report
enum ReportReason: String, Codable, CaseIterable {
    case spam          = "spam"
    case harassment    = "harassment"
    case hateSpeech    = "hate_speech"
    case misinformation = "misinformation"
    case offTopic      = "off_topic"
    case other         = "other"

    /// Localization key, callers must wrap this in `bundle.loc(...)`.
    var displayName: String {
        switch self {
        case .spam:           return "Spam"
        case .harassment:     return "Harassment"
        case .hateSpeech:     return "Hate speech"
        case .misinformation: return "Misinformation"
        case .offTopic:       return "Off topic"
        case .other:          return "Other"
        }
    }
}

/// A submitted report record returned from the API
struct Report: Identifiable, Decodable {
    let id: String
    let targetType: String
    let targetId: String
    let reason: ReportReason
    let status: String
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, status
        case targetType = "target_type"
        case targetId   = "target_id"
        case reason
        case createdAt  = "created_at"
    }
}

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

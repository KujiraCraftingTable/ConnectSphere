import Foundation

/// Payload dùng chung cho mọi loại user notification.
/// - mode_mismatch: suggestedMode / currentMode / reason
/// - connection_request / connection_accepted: fromUserId / fromDisplayName / fromAvatarColor / mode
/// - post_liked / post_commented / comment_replied: from* + excerpt (nội dung comment)
struct UserNotificationPayloadDTO: Decodable {
    let suggestedMode: String?
    let currentMode: String?
    let reason: String?
    let fromUserId: String?
    let fromDisplayName: String?
    let fromAvatarColor: String?
    let fromAvatarUrl: String?
    let mode: String?
    let excerpt: String?

    enum CodingKeys: String, CodingKey {
        case suggestedMode = "suggestedMode"
        case currentMode   = "currentMode"
        case reason
        case fromUserId      = "fromUserId"
        case fromDisplayName = "fromDisplayName"
        case fromAvatarColor = "fromAvatarColor"
        case fromAvatarUrl   = "fromAvatarUrl"
        case mode
        case excerpt
    }
}

struct UserNotificationDTO: Decodable, Identifiable {
    let id: String
    let type: String
    let postId: String?
    let payload: UserNotificationPayloadDTO
    let isRead: Bool
    let resolvedAt: Date?
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, type, payload
        case postId     = "post_id"
        case isRead     = "is_read"
        case resolvedAt = "resolved_at"
        case createdAt  = "created_at"
    }
}

struct UserNotificationListResponseDTO: Decodable {
    let data: [UserNotificationDTO]
    let unread: Int
}

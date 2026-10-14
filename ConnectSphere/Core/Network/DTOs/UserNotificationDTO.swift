import Foundation

/// Shared payload for every kind of user notification.
/// - mode_mismatch: suggestedMode / currentMode / reason
/// - connection_request / connection_accepted: from* + mode
/// - post_liked / post_commented / comment_replied / comment_liked: from* + excerpt + commentId
/// - message / meeting_* / group_*: the conversation card below, so the client
///   can open a chat without a second round trip
/// - community types: communityId + communityName + role/report details
///
/// Every field is optional: a row written by an older release, or by a type
/// this build doesn't know yet, must still decode rather than failing the
/// whole list.
struct UserNotificationPayloadDTO: Decodable {
    // AI mode suggestion
    let suggestedMode: String?
    let currentMode: String?
    let reason: String?

    // Actor
    let fromUserId: String?
    let fromDisplayName: String?
    let fromAvatarColor: String?
    let fromAvatarUrl: String?
    let mode: String?

    /// The skill someone endorsed (`skill_endorsed`).
    let skill: String?

    // Post / comment
    let excerpt: String?
    /// A comment that's only a photo (no text to quote).
    let commentPhoto: Bool?
    let commentId: String?
    let parentCommentId: String?
    let commentExcerpt: String?
    let postExcerpt: String?
    let postType: String?

    // Conversation card — everything ChatView needs to build a ChatPeer
    let conversationId: String?
    let isGroup: Bool?
    let groupName: String?
    let groupAvatarUrl: String?
    let groupAvatarColor: String?
    let memberCount: Int?
    let peerUserId: String?
    let peerDisplayName: String?
    let peerAvatarUrl: String?
    let peerAvatarColor: String?

    // Chat extras
    let preview: String?
    let lastMessageType: String?
    let messageId: String?
    let proposalId: String?
    let title: String?
    let startsAt: Date?
    let changeKind: String?
    let status: String?
    let emoji: String?

    // Community
    let communityId: String?
    let communityName: String?
    let requestId: String?
    let newRole: String?
    let previousRole: String?
    let reportCount: Int?
}

/// Where tapping a notification should take the user. Computed server-side, so
/// a routing fix ships with the backend rather than an App Store release.
struct NotificationDestinationDTO: Decodable {
    let kind: String
    let postId: String?
    let commentId: String?
    let userId: String?
    let conversationId: String?
    let messageId: String?
    let communityId: String?
}

struct UserNotificationDTO: Decodable, Identifiable {
    let id: String
    let type: String
    let postId: String?
    let payload: UserNotificationPayloadDTO
    let isRead: Bool
    let resolvedAt: Date?
    let createdAt: Date

    // Added by migration 026 — all optional so a response from an older
    // backend still decodes.
    let actorId: String?
    let communityId: String?
    let conversationId: String?
    let entityType: String?
    let entityId: String?
    let groupKey: String?
    let collapseCount: Int?
    let updatedAt: Date?
    let communityName: String?
    let category: String?
    let destination: NotificationDestinationDTO?

    enum CodingKeys: String, CodingKey {
        case id, type, payload, category, destination
        case postId         = "post_id"
        case isRead         = "is_read"
        case resolvedAt     = "resolved_at"
        case createdAt      = "created_at"
        case actorId        = "actor_id"
        case communityId    = "community_id"
        case conversationId = "conversation_id"
        case entityType     = "entity_type"
        case entityId       = "entity_id"
        case groupKey       = "group_key"
        case collapseCount  = "collapse_count"
        case updatedAt      = "updated_at"
        case communityName  = "community_name"
    }

    /// Rows are grouped on this in the list. Falls back to the id so a row
    /// without a key can never collapse into an unrelated group.
    var groupingKey: String { groupKey ?? "\(type):\(id)" }

    /// How many events this row represents — only chat rows ever exceed 1.
    var eventCount: Int { collapseCount ?? 1 }

    /// Newest-activity timestamp; a collapsed chat row is bumped on each message.
    var sortDate: Date { updatedAt ?? createdAt }
}

struct UserNotificationCountsDTO: Decodable {
    let total: Int?
    let social: Int?
    let community: Int?
    let chat: Int?
}

struct UserNotificationListResponseDTO: Decodable {
    let data: [UserNotificationDTO]
    let unread: Int
    let counts: UserNotificationCountsDTO?
    let hasMore: Bool?
    let nextCursor: String?
}

struct UnreadCountPayloadDTO: Decodable {
    let count: Int
}

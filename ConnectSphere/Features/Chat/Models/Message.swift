import Foundation

enum MessageType: String, Decodable {
    case text, image, video
}

enum MessageStatus: String, Decodable {
    case sent, delivered, read
}

/// Fixed reaction set shown in the quick-react picker — mirrors
/// `ALLOWED_REACTION_EMOJI` in backend/src/models/messageModel.js.
enum ReactionEmoji: String, CaseIterable {
    case heart = "❤️"
    case thumbsUp = "👍"
    case laugh = "😂"
    case wow = "😮"
    case sad = "😢"
    case fire = "🔥"
}

/// Compact preview of the message being replied to — embedded server-side so
/// the client never needs a second round-trip to render the quoted content.
struct RepliedMessage: Decodable, Equatable {
    let id: String
    let senderId: String
    let senderName: String
    let messageType: MessageType
    let isDeleted: Bool
    /// nil when the original was recalled — client shows a placeholder instead.
    let content: String?

    enum CodingKeys: String, CodingKey {
        case id
        case senderId    = "sender_id"
        case senderName  = "sender_name"
        case messageType = "message_type"
        case isDeleted   = "is_deleted"
        case content
    }
}

struct Message: Identifiable, Decodable, Equatable {
    let id: String
    let conversationId: String
    let senderId: String
    var content: String?
    let messageType: MessageType
    var mediaUrl: String?
    var status: MessageStatus
    let createdAt: Date
    let replyToMessageId: String?
    var repliedMessage: RepliedMessage?
    /// emoji → user ids who reacted with it
    var reactions: [String: [String]]
    /// Optional vì response insert không trả field này — nil nghĩa là chưa thu hồi
    private var deletedFlag: Bool?

    var isDeleted: Bool { deletedFlag ?? false }

    /// Đánh dấu thu hồi tại chỗ (khi nhận socket event hoặc sau khi gọi API)
    mutating func markDeleted() {
        deletedFlag = true
        content  = nil
        mediaUrl = nil
    }

    enum CodingKeys: String, CodingKey {
        case id, content, status, reactions
        case conversationId   = "conversation_id"
        case senderId         = "sender_id"
        case messageType      = "message_type"
        case mediaUrl         = "media_url"
        case createdAt        = "created_at"
        case deletedFlag      = "is_deleted"
        case replyToMessageId = "reply_to_message_id"
        case repliedMessage   = "replied_message"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        conversationId = try c.decode(String.self, forKey: .conversationId)
        senderId = try c.decode(String.self, forKey: .senderId)
        content = try c.decodeIfPresent(String.self, forKey: .content)
        messageType = try c.decode(MessageType.self, forKey: .messageType)
        mediaUrl = try c.decodeIfPresent(String.self, forKey: .mediaUrl)
        status = try c.decode(MessageStatus.self, forKey: .status)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        replyToMessageId = try c.decodeIfPresent(String.self, forKey: .replyToMessageId)
        repliedMessage = try c.decodeIfPresent(RepliedMessage.self, forKey: .repliedMessage)
        reactions = try c.decodeIfPresent([String: [String]].self, forKey: .reactions) ?? [:]
        deletedFlag = try c.decodeIfPresent(Bool.self, forKey: .deletedFlag)
    }

    /// True when this message was sent by the given user.
    func isOwn(userId: String) -> Bool { senderId == userId }

    /// Absolute media URL for displaying images/videos.
    func absoluteMediaURL() -> URL? {
        guard let path = mediaUrl else { return nil }
        return URL(string: APIConfig.serverBase + path)
    }

    /// The current user's own reaction emoji on this message, if any — used to
    /// highlight the selected emoji in the picker and drive toggle behaviour.
    func myReaction(userId: String) -> String? {
        reactions.first { _, userIds in userIds.contains(userId) }?.key
    }

    /// Reactions as a stable, display-ordered list of (emoji, count).
    var reactionSummary: [(emoji: String, count: Int)] {
        reactions.map { ($0.key, $0.value.count) }.sorted { $0.emoji < $1.emoji }
    }
}

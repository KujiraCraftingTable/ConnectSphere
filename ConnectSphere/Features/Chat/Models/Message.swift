import Foundation

enum MessageType: String, Decodable {
    case text, image, video
}

enum MessageStatus: String, Decodable {
    case sent, delivered, read
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
        case id, content, status
        case conversationId = "conversation_id"
        case senderId       = "sender_id"
        case messageType    = "message_type"
        case mediaUrl       = "media_url"
        case createdAt      = "created_at"
        case deletedFlag    = "is_deleted"
    }

    /// True when this message was sent by the given user.
    func isOwn(userId: String) -> Bool { senderId == userId }

    /// Absolute media URL for displaying images/videos.
    func absoluteMediaURL() -> URL? {
        guard let path = mediaUrl else { return nil }
        return URL(string: APIConfig.serverBase + path)
    }
}

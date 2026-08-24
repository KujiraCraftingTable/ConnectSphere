import Foundation

struct Conversation: Identifiable, Decodable, Equatable {
    let id: String
    let mode: String
    let updatedAt: Date

    let otherUserId: String
    let otherUserUsername: String
    let otherUserName: String
    let otherUserAvatarColor: String
    let otherUserJobTitle: String?
    let otherUserNickname: String?

    let lastMessageContent: String?
    let lastMessageType: String?
    let lastMessageSenderId: String?
    let lastMessageAt: Date?

    let unreadCount: Int

    enum CodingKeys: String, CodingKey {
        case id, mode
        case updatedAt          = "updated_at"
        case otherUserId        = "other_user_id"
        case otherUserUsername  = "other_user_username"
        case otherUserName      = "other_user_name"
        case otherUserAvatarColor = "other_user_avatar_color"
        case otherUserJobTitle  = "other_user_job_title"
        case otherUserNickname  = "other_user_nickname"
        case lastMessageContent = "last_message_content"
        case lastMessageType    = "last_message_type"
        case lastMessageSenderId = "last_message_sender_id"
        case lastMessageAt      = "last_message_at"
        case unreadCount        = "unread_count"
    }

    /// True when the current user has unread messages in this conversation.
    var hasUnread: Bool { unreadCount > 0 }

    /// Name to show for the other person: shared nickname overrides real name.
    var displayName: String { otherUserNickname ?? otherUserName }

    /// Formatted preview text for the conversation list row.
    func previewText(currentUserId: String) -> String {
        let isOwn = lastMessageSenderId == currentUserId
        let prefix = isOwn ? "You: " : ""
        switch lastMessageType {
        case "image":   return "\(prefix)📷 Photo"
        case "video":   return "\(prefix)🎥 Video"
        // Meeting proposals carry no text content, so this must be checked before
        // the nil-content guard below (which would otherwise show "No messages yet").
        case "meeting": return "\(prefix)📅 Meeting proposal"
        default:
            guard let content = lastMessageContent else { return "No messages yet" }
            return "\(prefix)\(content)"
        }
    }
}

import Foundation

/// Someone in the people row at the top of Messages: a 1:1 chat partner in
/// this mode. Comes from `/messages/contacts`, not the chat list, so deleting
/// or archiving a chat doesn't take the person off the row.
struct ChatContact: Decodable, Identifiable, Equatable {
    let conversationId: String
    let userId: String
    let username: String
    let name: String
    /// My private nickname for them in this chat, if I set one.
    let nickname: String?
    let avatarUrl: String?
    let avatarColor: String
    let lastMessageAt: Date

    var id: String { userId }
    var displayName: String { nickname ?? name }
    var peer: ChatPeer { .direct(otherUserId: userId, name: displayName, avatarColor: avatarColor, avatarUrl: avatarUrl) }

    enum CodingKeys: String, CodingKey {
        case username, nickname
        case conversationId = "conversation_id"
        case userId         = "user_id"
        case name           = "display_name"
        case avatarUrl      = "avatar_url"
        case avatarColor    = "avatar_color"
        case lastMessageAt  = "last_message_at"
    }
}

import Foundation

enum MessageType: String, Decodable {
    case text, image, video, meeting
}

/// RSVP status for a meeting proposal — local to Chat (mirrors the shape of
/// Communities' `RsvpStatus` in `CommunityPost.swift`, but declared separately
/// since that one is anchored to community events/posts, not messages).
enum MeetingRsvpStatus: String, Codable {
    case going
    case maybe
    case notGoing = "not_going"

    /// English fallback / localization key — same values as `RsvpStatus.label`.
    var label: String {
        switch self {
        case .going:    return "Going"
        case .maybe:    return "Maybe"
        case .notGoing: return "Can't go"
        }
    }

    var icon: String {
        switch self {
        case .going:    return "checkmark.circle.fill"
        case .maybe:    return "questionmark.circle.fill"
        case .notGoing: return "xmark.circle.fill"
        }
    }
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

/// Meeting/appointment proposal embedded in a `.meeting` message — mirrors
/// Communities' `EventData` shape (title/location/starts_at/ends_at + RSVP),
/// but anchored to a chat message instead of a community post. `rsvps` is a
/// status → user-ids map, the exact same convention as `Message.reactions`
/// (see `backend/src/models/messageModel.js`'s `MESSAGE_EMBED_SELECT`), so the
/// client derives counts and "my response" locally without a per-user query.
struct MeetingProposal: Decodable, Equatable {
    let id: String
    let title: String
    let location: String?
    let startsAt: Date
    let endsAt: Date?
    /// "active" | "cancelled"
    var status: String
    /// rsvp status ("going"/"maybe"/"not_going") → user ids who responded with it
    var rsvps: [String: [String]]

    enum CodingKeys: String, CodingKey {
        case id, title, location, status, rsvps
        case startsAt = "starts_at"
        case endsAt   = "ends_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        location = try c.decodeIfPresent(String.self, forKey: .location)
        startsAt = try c.decode(Date.self, forKey: .startsAt)
        endsAt = try c.decodeIfPresent(Date.self, forKey: .endsAt)
        status = try c.decode(String.self, forKey: .status)
        rsvps = try c.decodeIfPresent([String: [String]].self, forKey: .rsvps) ?? [:]
    }

    var isCancelled: Bool { status == "cancelled" }

    /// Number of RSVPs for a given status.
    func count(for status: MeetingRsvpStatus) -> Int {
        rsvps[status.rawValue]?.count ?? 0
    }

    /// The given user's RSVP status on this proposal, if any.
    func myResponse(userId: String) -> MeetingRsvpStatus? {
        for (statusKey, userIds) in rsvps where userIds.contains(userId) {
            return MeetingRsvpStatus(rawValue: statusKey)
        }
        return nil
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
    /// Present only when `messageType == .meeting` — the proposal's details/RSVP state.
    var meetingProposal: MeetingProposal?
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
        case meetingProposal  = "meeting_proposal"
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
        meetingProposal = try c.decodeIfPresent(MeetingProposal.self, forKey: .meetingProposal)
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

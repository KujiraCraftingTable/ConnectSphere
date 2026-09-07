import Foundation

enum MessageType: String, Decodable {
    case text, image, video, meeting, voice
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

/// Reminder lead time for a meeting proposal — one of 4 fixed calendar-app-style
/// presets chosen at creation (`MeetingProposalComposerView`), which computes the
/// absolute `MeetingProposal.reminderAt` instant (7am local, N days before
/// `startsAt`) client-side and sends both to the server. Mirrors
/// `MeetingRsvpStatus`'s exact style (`label`/`icon`).
enum MeetingReminderOffset: String, CaseIterable, Codable {
    case onDay = "on_day"
    case oneDayBefore = "1_day_before"
    case twoDaysBefore = "2_days_before"
    case oneWeekBefore = "1_week_before"

    /// English fallback / localization key.
    var label: String {
        switch self {
        case .onDay:         return "On the day"
        case .oneDayBefore:  return "1 day before"
        case .twoDaysBefore: return "2 days before"
        case .oneWeekBefore: return "1 week before"
        }
    }

    var icon: String { "bell.fill" }

    /// Days before `startsAt` the reminder fires (at 7am local time).
    var daysBefore: Int {
        switch self {
        case .onDay:         return 0
        case .oneDayBefore:  return 1
        case .twoDaysBefore: return 2
        case .oneWeekBefore: return 7
        }
    }

    /// Computes the absolute instant this reminder should fire for a meeting
    /// starting at `startsAt`: 7am on the day `daysBefore` days before
    /// `startsAt`'s calendar day, in the given calendar (defaults to the
    /// device's current calendar/timezone — "local" per the product decision,
    /// deliberately NOT hardcoded UTC, since there's no per-user timezone
    /// tracked server-side; see Phase 2's `reminder_at` design note).
    func reminderDate(before startsAt: Date, calendar: Calendar = .current) -> Date {
        let startOfStartDay = calendar.startOfDay(for: startsAt)
        guard let targetDay = calendar.date(byAdding: .day, value: -daysBefore, to: startOfStartDay) else {
            return startsAt
        }
        return calendar.date(byAdding: .hour, value: 7, to: targetDay) ?? targetDay
    }
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

/// One pinned-message row, as returned by `GET .../pins` — flatter than
/// `Message` (sender name + pin metadata inline, no reactions/status/
/// reply-thread fields) since the pinned list only ever needs a preview plus
/// who/when pinned it. `id` decodes from the wire's `message_id` (the
/// message's own id) rather than `message_pins.id` — that's what
/// `DELETE .../pins/:messageId` and `ChatView.jumpToMessage(_:)` both expect;
/// the pin row's own id is never needed on this side. Reconciled against the
/// real backend (`messageModel.listPins`, `backend/src/models/messageModel.js`).
struct PinnedMessage: Identifiable, Decodable, Equatable {
    let id: String
    let content: String?
    let messageType: MessageType
    let senderId: String
    let senderName: String
    let pinnedBy: String
    let pinnedAt: Date
    let expiresAt: Date?
    private var deletedFlag: Bool?

    var isDeleted: Bool { deletedFlag ?? false }

    enum CodingKeys: String, CodingKey {
        case id = "message_id"
        case content
        case messageType = "message_type"
        case senderId     = "sender_id"
        case senderName   = "sender_name"
        case pinnedBy     = "pinned_by"
        case pinnedAt     = "pinned_at"
        case expiresAt    = "expires_at"
        case deletedFlag  = "is_deleted"
    }

    /// Type-appropriate one-line preview, matching `ChatView.replyingToBar`'s
    /// fallback-text convention for non-text messages. Uses `Bundle.app`
    /// since this model has no `@Environment(\.appBundle)` access (same
    /// pattern `Bundle.app`'s own doc comment calls out for ViewModel use).
    var preview: String {
        if isDeleted { return Bundle.app.loc("Message unsent") }
        switch messageType {
        case .text:    return content ?? ""
        case .image:   return "📷 " + Bundle.app.loc("Photo")
        case .video:   return "📹 " + Bundle.app.loc("Video")
        case .meeting: return "📅 " + Bundle.app.loc("Meeting")
        case .voice:   return "🎤 " + Bundle.app.loc("Voice message")
        }
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
    /// Reminder lead-time label, raw ("on_day"/"1_day_before"/"2_days_before"/
    /// "1_week_before") rather than the `MeetingReminderOffset` enum itself —
    /// same decode-safety convention as `status` (a future server-added value
    /// shouldn't fail decoding the whole proposal). Use `reminderOffsetValue`
    /// for the typed form.
    var reminderOffset: String
    /// Absolute instant the reminder fires — precomputed client-side at
    /// creation (7am local, N days before `startsAt`) and echoed back by the server.
    var reminderAt: Date
    /// Set once the reminder job has sent it; nil while still pending.
    var reminderSentAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, title, location, status, rsvps
        case startsAt = "starts_at"
        case endsAt   = "ends_at"
        case reminderOffset = "reminder_offset"
        case reminderAt     = "reminder_at"
        case reminderSentAt = "reminder_sent_at"
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
        // Required server-side (NOT NULL / server-defaulted), but decoded
        // leniently with a fallback so older cached/mock payloads without
        // these fields don't blow up decoding the whole message.
        reminderOffset = try c.decodeIfPresent(String.self, forKey: .reminderOffset)
            ?? MeetingReminderOffset.oneDayBefore.rawValue
        reminderAt = try c.decodeIfPresent(Date.self, forKey: .reminderAt) ?? startsAt
        reminderSentAt = try c.decodeIfPresent(Date.self, forKey: .reminderSentAt)
    }

    var isCancelled: Bool { status == "cancelled" }

    /// Typed form of `reminderOffset`, nil if the server ever sends an
    /// unrecognized value (decode-safe, matches `myResponse`'s same pattern).
    var reminderOffsetValue: MeetingReminderOffset? { MeetingReminderOffset(rawValue: reminderOffset) }

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
    /// User ids who have received (delivered) this message — same map-shaped
    /// convention as `reactions`/`MeetingProposal.rsvps`, unified onto a single
    /// per-participant model instead of a `sent/delivered/read` enum so groups
    /// can represent "delivered to 3 of 5" without a second receipt system.
    var deliveredTo: [String]
    /// User ids who have read this message. Read implies delivered — callers
    /// appending to this array must also append to `deliveredTo`.
    var readBy: [String]
    let createdAt: Date
    let replyToMessageId: String?
    var repliedMessage: RepliedMessage?
    /// emoji → user ids who reacted with it
    var reactions: [String: [String]]
    /// Present only when `messageType == .meeting` — the proposal's details/RSVP state.
    var meetingProposal: MeetingProposal?
    /// Present only when `messageType == .voice` — playback length in seconds.
    var voiceDurationSeconds: Int?
    /// Present only when `messageType == .voice` — a fixed-length (~40 point)
    /// array of normalized 0.0-1.0 amplitude samples captured client-side at
    /// record time, so every viewer renders the identical waveform with no
    /// audio re-analysis on the receiving end.
    var voiceWaveform: [Float]?
    /// Optional because the insert response doesn't return this field — nil means not recalled
    private var deletedFlag: Bool?

    var isDeleted: Bool { deletedFlag ?? false }

    /// Mark as recalled in place (when receiving a socket event or after calling the API)
    mutating func markDeleted() {
        deletedFlag = true
        content  = nil
        mediaUrl = nil
    }

    enum CodingKeys: String, CodingKey {
        case id, content, reactions
        case conversationId   = "conversation_id"
        case senderId         = "sender_id"
        case messageType      = "message_type"
        case mediaUrl         = "media_url"
        case deliveredTo      = "delivered_to"
        case readBy           = "read_by"
        case createdAt        = "created_at"
        case deletedFlag      = "is_deleted"
        case replyToMessageId = "reply_to_message_id"
        case repliedMessage   = "replied_message"
        case meetingProposal  = "meeting_proposal"
        case voiceDurationSeconds = "voice_duration_seconds"
        case voiceWaveform        = "voice_waveform"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        conversationId = try c.decode(String.self, forKey: .conversationId)
        senderId = try c.decode(String.self, forKey: .senderId)
        content = try c.decodeIfPresent(String.self, forKey: .content)
        messageType = try c.decode(MessageType.self, forKey: .messageType)
        mediaUrl = try c.decodeIfPresent(String.self, forKey: .mediaUrl)
        // Default to [] for decode-safety — absent on some embed shapes
        // (e.g. a just-sent optimistic echo) rather than always present.
        deliveredTo = try c.decodeIfPresent([String].self, forKey: .deliveredTo) ?? []
        readBy = try c.decodeIfPresent([String].self, forKey: .readBy) ?? []
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        replyToMessageId = try c.decodeIfPresent(String.self, forKey: .replyToMessageId)
        repliedMessage = try c.decodeIfPresent(RepliedMessage.self, forKey: .repliedMessage)
        reactions = try c.decodeIfPresent([String: [String]].self, forKey: .reactions) ?? [:]
        deletedFlag = try c.decodeIfPresent(Bool.self, forKey: .deletedFlag)
        meetingProposal = try c.decodeIfPresent(MeetingProposal.self, forKey: .meetingProposal)
        voiceDurationSeconds = try c.decodeIfPresent(Int.self, forKey: .voiceDurationSeconds)
        voiceWaveform = try c.decodeIfPresent([Float].self, forKey: .voiceWaveform)
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

    // MARK: - Delivery / read receipts

    /// True if `userId` has received this message.
    func isDelivered(to userId: String) -> Bool { deliveredTo.contains(userId) }

    /// True if `userId` has read this message.
    func isRead(by userId: String) -> Bool { readBy.contains(userId) }

    /// How many of the given participants (typically the conversation's
    /// *other* members — the sender excluded) have read this message. Takes
    /// the participant list as a parameter rather than storing it on `Message`
    /// itself, since `Message` has no notion of which conversation/roster it
    /// belongs to beyond `conversationId`.
    func readCount(among participantIds: [String]) -> Int {
        participantIds.filter { readBy.contains($0) }.count
    }

    /// How many of the given participants have received this message.
    func deliveredCount(among participantIds: [String]) -> Int {
        participantIds.filter { deliveredTo.contains($0) }.count
    }

    /// True when every one of the given participants has read this message
    /// (e.g. "read by all" for a 1:1 chat's single other participant, or a
    /// group's full non-sender roster).
    func isReadByAll(of participantIds: [String]) -> Bool {
        !participantIds.isEmpty && participantIds.allSatisfy { readBy.contains($0) }
    }
}

import Foundation

/// Discriminates a conversation's "other side": a single other person (1:1)
/// vs. a group's name/photo/member count. Decoded from the row's `is_group`
/// flag so every downstream call site is compiler-exhaustive-checked, rather
/// than relying on optional-field discipline over one flat struct.
enum ConversationPeer: Equatable {
    case direct(
        otherUserId: String,
        username: String,
        name: String,
        avatarColor: String,
        avatarUrl: String?,
        jobTitle: String?,
        nickname: String?
    )
    case group(
        name: String,
        avatarUrl: String?,
        avatarColor: String?,
        memberCount: Int
    )
}

/// A 1-on-1 chat with someone who isn't a friend yet (migration 040).
enum MessageRequestState: String, Decodable {
    /// They wrote to me; it sits in Waiting until I accept, reply, or we become friends.
    case waiting
    /// I wrote to them; I can send `MessageRequests.limit` messages until they accept.
    case sent
}

/// A row from `GET /messages/conversations`. Either a 1:1 or a group
/// conversation. The "irrelevant half" of the backend row (direct-only or
/// group-only columns) is NULL and folded into `peer` at decode time.
struct Conversation: Identifiable, Decodable, Equatable {
    let id: String
    let mode: String
    let isGroup: Bool
    let theme: String?
    let updatedAt: Date
    // `var`: the Messages swipe actions update these in place before the server answers.
    var mutedUntil: Date?
    /// Pinned to the top of *my* list (each participant pins independently).
    var isPinned: Bool
    /// Moved out of *my* main list; a new message brings it back.
    var isArchived: Bool
    var requestState: MessageRequestState?
    /// How many more messages I can send before they accept (`.sent` only).
    var requestsLeft: Int?
    let peer: ConversationPeer
    /// 1:1 with the official account: its seal shows beside the name.
    let isOfficialPeer: Bool

    let lastMessageContent: String?
    let lastMessageType: String?
    /// Photo count when the last message is an album.
    let lastMessageMediaCount: Int?
    let lastMessageSenderId: String?
    let lastMessageAt: Date?
    /// The newest thing in the chat is a theme/nickname/accept note.
    let lastEvent: LastEvent?

    var unreadCount: Int

    /// A chat note as the inbox preview: the same fields as `ChatEvent`.
    struct LastEvent: Decodable, Equatable, Hashable {
        let kind: ChatEvent.Kind
        let actorId: String
        let actorName: String
        let theme: String?
        let targetId: String?
        let targetName: String?
        let nickname: String?

        enum CodingKeys: String, CodingKey {
            case kind, theme, nickname
            case actorId = "actor_id"
            case actorName = "actor_name"
            case targetId = "target_id"
            case targetName = "target_name"
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, mode, theme
        case isGroup   = "is_group"
        case updatedAt = "updated_at"
        case mutedUntil = "muted_until"
        case pinnedAt   = "pinned_at"
        case archivedAt = "archived_at"
        case requestState = "request_state"
        case requestsLeft = "requests_left"

        case otherUserId          = "other_user_id"
        case otherUserUsername    = "other_user_username"
        case otherUserName        = "other_user_name"
        case otherUserAvatarColor = "other_user_avatar_color"
        case otherUserAvatarUrl   = "other_user_avatar_url"
        case otherUserJobTitle    = "other_user_job_title"
        case otherUserNickname    = "other_user_nickname"
        case otherUserIsOfficial  = "other_user_is_official"

        case name
        case avatarUrl   = "avatar_url"
        case avatarColor = "avatar_color"
        case memberCount = "member_count"

        case lastMessageContent  = "last_message_content"
        case lastMessageType     = "last_message_type"
        case lastMessageMediaCount = "last_message_media_count"
        case lastMessageSenderId = "last_message_sender_id"
        case lastMessageAt       = "last_message_at"
        case lastEvent           = "last_event"
        case unreadCount         = "unread_count"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        mode = try c.decode(String.self, forKey: .mode)
        isGroup = try c.decodeIfPresent(Bool.self, forKey: .isGroup) ?? false
        theme = try c.decodeIfPresent(String.self, forKey: .theme)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        mutedUntil = try c.decodeIfPresent(Date.self, forKey: .mutedUntil)
        isPinned = try c.decodeIfPresent(Date.self, forKey: .pinnedAt) != nil
        isArchived = try c.decodeIfPresent(Date.self, forKey: .archivedAt) != nil
        requestState = try? c.decodeIfPresent(MessageRequestState.self, forKey: .requestState)
        requestsLeft = try c.decodeIfPresent(Int.self, forKey: .requestsLeft)

        if isGroup {
            let name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
            let avatarUrl = try c.decodeIfPresent(String.self, forKey: .avatarUrl)
            let avatarColor = try c.decodeIfPresent(String.self, forKey: .avatarColor)
            let memberCount = try c.decodeIfPresent(Int.self, forKey: .memberCount) ?? 0
            peer = .group(name: name, avatarUrl: avatarUrl, avatarColor: avatarColor, memberCount: memberCount)
        } else {
            // A 1:1 conversation whose peer deleted their account comes back with
            // null identity fields. Decode leniently so one such row never
            // fails the whole conversation list.
            let otherUserId = try c.decodeIfPresent(String.self, forKey: .otherUserId) ?? ""
            let username = try c.decodeIfPresent(String.self, forKey: .otherUserUsername) ?? "deleted"
            let name = try c.decodeIfPresent(String.self, forKey: .otherUserName) ?? "Deleted User"
            let avatarColor = try c.decodeIfPresent(String.self, forKey: .otherUserAvatarColor) ?? "#9E9E9E"
            let avatarUrl = try c.decodeIfPresent(String.self, forKey: .otherUserAvatarUrl)
            let jobTitle = try c.decodeIfPresent(String.self, forKey: .otherUserJobTitle)
            let nickname = try c.decodeIfPresent(String.self, forKey: .otherUserNickname)
            peer = .direct(
                otherUserId: otherUserId, username: username, name: name,
                avatarColor: avatarColor, avatarUrl: avatarUrl,
                jobTitle: jobTitle, nickname: nickname
            )
        }

        lastMessageContent = try c.decodeIfPresent(String.self, forKey: .lastMessageContent)
        lastMessageType = try c.decodeIfPresent(String.self, forKey: .lastMessageType)
        lastMessageMediaCount = try c.decodeIfPresent(Int.self, forKey: .lastMessageMediaCount)
        lastMessageSenderId = try c.decodeIfPresent(String.self, forKey: .lastMessageSenderId)
        lastMessageAt = try c.decodeIfPresent(Date.self, forKey: .lastMessageAt)
        lastEvent = (try? c.decodeIfPresent(LastEvent.self, forKey: .lastEvent)) ?? nil
        unreadCount = try c.decodeIfPresent(Int.self, forKey: .unreadCount) ?? 0
        isOfficialPeer = try c.decodeIfPresent(Bool.self, forKey: .otherUserIsOfficial) ?? false
    }

    /// True when the current user has unread messages in this conversation.
    var hasUnread: Bool { unreadCount > 0 }

    var isMuted: Bool { mutedUntil.map { $0 > Date() } ?? false }

    /// The other 1:1 participant's id. Nil for groups (no single "other person").
    var otherUserId: String? {
        if case .direct(let id, _, _, _, _, _, _) = peer { return id }
        return nil
    }

    /// Name to show for this conversation: shared nickname overrides real name
    /// for 1:1; the group's name for groups.
    var displayName: String {
        switch peer {
        case .direct(_, _, let name, _, _, _, let nickname):
            return nickname ?? name
        case .group(let name, _, _, _):
            return name
        }
    }

    /// Whose initial the avatar shows: always the real name (or the group's),
    /// never a nickname, which only renames them in this chat.
    var avatarName: String {
        switch peer {
        case .direct(_, _, let name, _, _, _, _): return name
        case .group(let name, _, _, _): return name
        }
    }

    /// Fallback avatar color (used when there's no photo, or as the base of a
    /// group's avatar stack when the group has no dedicated photo/color).
    var avatarColor: String {
        switch peer {
        case .direct(_, _, _, let color, _, _, _): return color
        case .group(_, _, let color, _): return color ?? "#8A8F98"
        }
    }

    /// Photo URL (relative path from the server), if set.
    var avatarUrl: String? {
        switch peer {
        case .direct(_, _, _, _, let url, _, _): return url
        case .group(_, let url, _, _): return url
        }
    }

    /// Member count, 0 for 1:1 (always exactly 2 there, so callers should
    /// branch on `isGroup` rather than rely on this for 1:1 rows).
    var memberCount: Int {
        if case .group(_, _, _, let count) = peer { return count }
        return 0
    }

    /// Formatted preview text for the conversation list row. Uses `Bundle.app`
    /// since this model has no `@Environment(\.appBundle)` access. Same
    /// convention as `Message.preview`, which this mirrors.
    func previewText(currentUserId: String) -> String {
        let isOwn = lastMessageSenderId == currentUserId
        let prefix = isOwn ? Bundle.app.loc("You: ") : ""
        switch lastMessageType {
        case "image":   return "\(prefix)📷 " + Bundle.app.loc("Photo")
        case "video":   return "\(prefix)🎥 " + Bundle.app.loc("Video")
        case "album":   return prefix + Message.albumPreview(caption: lastMessageContent, count: lastMessageMediaCount)
        // Meeting proposals carry no text content, so this must be checked before
        // the nil-content guard below (which would otherwise show "No messages yet").
        case "meeting": return "\(prefix)📅 " + Bundle.app.loc("Meeting proposal")
        case "poll":    return "\(prefix)📊 " + (lastMessageContent ?? Bundle.app.loc("Poll"))
        case "post":    return "\(prefix)📰 " + ((lastMessageContent?.isEmpty == false ? lastMessageContent : nil) ?? Bundle.app.loc("Shared a post"))
        case "voice":   return "\(prefix)🎤 " + Bundle.app.loc("Voice message")
        case "event":
            guard let e = lastEvent else { return Bundle.app.loc("No messages yet") }
            return ChatEvent.text(kind: e.kind, actorId: e.actorId, actorName: e.actorName, theme: e.theme,
                                  targetId: e.targetId, targetName: e.targetName, nickname: e.nickname,
                                  currentUserId: currentUserId, bundle: Bundle.app)
        default:
            guard let content = lastMessageContent else { return Bundle.app.loc("No messages yet") }
            return "\(prefix)\(content)"
        }
    }
}

// MARK: - ChatPeer (lean UI descriptor for ChatView/ChatSettingsView)

/// What `ChatView`/`ChatSettingsView` need to render their header/settings,
/// a leaner subset of `ConversationPeer`'s fields (no username/job title,
/// which those two views never display). Kept separate from `ConversationPeer`
/// so call sites that don't have a full `Conversation` (e.g. opening chat from
/// a connections row or a user profile) can build one without placeholder values.
enum ChatPeer: Hashable {
    case direct(otherUserId: String, name: String, avatarColor: String, avatarUrl: String?)
    case group(name: String, avatarUrl: String?, avatarColor: String?, memberCount: Int)

    var isGroup: Bool {
        if case .group = self { return true }
        return false
    }

    var otherUserId: String? {
        if case .direct(let id, _, _, _) = self { return id }
        return nil
    }

    var name: String {
        switch self {
        case .direct(_, let name, _, _): return name
        case .group(let name, _, _, _): return name
        }
    }

    var avatarColor: String {
        switch self {
        case .direct(_, _, let color, _): return color
        case .group(_, _, let color, _): return color ?? "#8A8F98"
        }
    }

    var avatarUrl: String? {
        switch self {
        case .direct(_, _, _, let url): return url
        case .group(_, let url, _, _): return url
        }
    }

    var memberCount: Int? {
        if case .group(_, _, _, let count) = self { return count }
        return nil
    }
}

extension ChatPeer {
    /// Builds a `ChatPeer` from a conversation list row. Used when navigating
    /// into `ChatView` straight from `ConversationListView`'s row list.
    init(_ conversation: Conversation) {
        switch conversation.peer {
        case .direct(let otherUserId, _, let name, let avatarColor, let avatarUrl, _, let nickname):
            self = .direct(otherUserId: otherUserId, name: nickname ?? name, avatarColor: avatarColor, avatarUrl: avatarUrl)
        case .group(let name, let avatarUrl, let avatarColor, let memberCount):
            self = .group(name: name, avatarUrl: avatarUrl, avatarColor: avatarColor, memberCount: memberCount)
        }
    }
}

/// A row from `GET /messages/search`. A normal conversation-list row (same
/// JSON shape `Conversation` already decodes) plus what matched and why.
/// Composed rather than duplicating `Conversation`'s field list: reading a
/// second keyed container from the same decoder is well-defined and doesn't
/// consume/invalidate what `Conversation`'s own decode already read.
struct ConversationSearchHit: Decodable, Identifiable {
    let conversation: Conversation
    /// "name" (the conversation/participant name matched) or "message"
    /// (a message's content matched).
    let matchType: String
    let matchedMessageId: String?
    let matchedSnippet: String?

    var id: String { conversation.id + "-" + (matchedMessageId ?? "name") }

    enum CodingKeys: String, CodingKey {
        case matchType = "match_type"
        case matchedMessageId = "matched_message_id"
        case matchedSnippet = "matched_snippet"
    }

    init(from decoder: Decoder) throws {
        conversation = try Conversation(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        matchType = try c.decode(String.self, forKey: .matchType)
        matchedMessageId = try c.decodeIfPresent(String.self, forKey: .matchedMessageId)
        matchedSnippet = try c.decodeIfPresent(String.self, forKey: .matchedSnippet)
    }
}

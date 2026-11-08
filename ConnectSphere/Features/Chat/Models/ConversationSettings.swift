import SwiftUI

/// Discriminates a conversation-settings snapshot's "other side" the same way
/// `ConversationPeer` does for list rows: a single other person (1:1) vs. a
/// group's identity + member roster. The backend has no explicit `is_group`
/// field on this response, but group responses always carry a `members`
/// array and 1:1 responses never do. A safe decode-time discriminant.
enum ConversationSettingsPeer: Equatable {
    case direct(
        otherUserId: String,
        otherUserUsername: String?,
        otherUserName: String,
        otherUserAvatarColor: String,
        otherUserJobTitle: String?,
        otherUserNickname: String?
    )
    case group(
        id: String,
        name: String,
        avatarUrl: String?,
        avatarColor: String?,
        createdBy: String,
        members: [GroupMember]
    )
}

/// Settings snapshot for a conversation (from `GET .../settings`), 1:1 or
/// group. `theme` is shared between all participants; `mutedUntil` is the
/// current user's own mute state (present for 1:1; the group settings
/// response does not currently return it. See `ChatViewModel`/report notes).
struct ConversationSettings: Decodable, Equatable {
    let theme: String?
    let mutedUntil: Date?
    let peer: ConversationSettingsPeer
    /// 1-on-1 only: whether this chat is still a message request.
    let requestState: MessageRequestState?
    let requestsLeft: Int?
    /// 1-on-1 with the official account (either side): messages can't be unsent.
    let withOfficial: Bool
    /// When this chat's message request was accepted (nil if it never was one).
    let requestAcceptedAt: Date?
    /// I started that request.
    let requestFromMe: Bool

    enum CodingKeys: String, CodingKey {
        case id, theme, members
        case mutedUntil           = "muted_until"
        case requestState         = "request_state"
        case requestsLeft         = "requests_left"
        case withOfficial         = "with_official"
        case requestAcceptedAt    = "request_accepted_at"
        case requestFromMe        = "request_from_me"
        case otherUserId          = "other_user_id"
        case otherUserUsername    = "other_user_username"
        case otherUserName        = "other_user_name"
        case otherUserAvatarColor = "other_user_avatar_color"
        case otherUserJobTitle    = "other_user_job_title"
        case otherUserNickname    = "other_user_nickname"
        case name
        case avatarUrl   = "avatar_url"
        case avatarColor = "avatar_color"
        case createdBy   = "created_by"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        requestState = try? c.decodeIfPresent(MessageRequestState.self, forKey: .requestState)
        requestsLeft = try c.decodeIfPresent(Int.self, forKey: .requestsLeft)
        withOfficial = try c.decodeIfPresent(Bool.self, forKey: .withOfficial) ?? false
        requestAcceptedAt = (try? c.decodeIfPresent(Date.self, forKey: .requestAcceptedAt)) ?? nil
        requestFromMe = try c.decodeIfPresent(Bool.self, forKey: .requestFromMe) ?? false
        theme = try c.decodeIfPresent(String.self, forKey: .theme)
        mutedUntil = try c.decodeIfPresent(Date.self, forKey: .mutedUntil)

        if let members = try c.decodeIfPresent([GroupMember].self, forKey: .members) {
            let id = try c.decode(String.self, forKey: .id)
            let name = try c.decode(String.self, forKey: .name)
            let avatarUrl = try c.decodeIfPresent(String.self, forKey: .avatarUrl)
            let avatarColor = try c.decodeIfPresent(String.self, forKey: .avatarColor)
            let createdBy = try c.decode(String.self, forKey: .createdBy)
            peer = .group(id: id, name: name, avatarUrl: avatarUrl, avatarColor: avatarColor,
                           createdBy: createdBy, members: members)
        } else {
            let otherUserId = try c.decode(String.self, forKey: .otherUserId)
            let otherUserUsername = try c.decodeIfPresent(String.self, forKey: .otherUserUsername)
            let otherUserName = try c.decode(String.self, forKey: .otherUserName)
            let otherUserAvatarColor = try c.decode(String.self, forKey: .otherUserAvatarColor)
            let otherUserJobTitle = try c.decodeIfPresent(String.self, forKey: .otherUserJobTitle)
            let otherUserNickname = try c.decodeIfPresent(String.self, forKey: .otherUserNickname)
            peer = .direct(
                otherUserId: otherUserId, otherUserUsername: otherUserUsername,
                otherUserName: otherUserName, otherUserAvatarColor: otherUserAvatarColor,
                otherUserJobTitle: otherUserJobTitle, otherUserNickname: otherUserNickname
            )
        }
    }

    var isGroup: Bool {
        if case .group = peer { return true }
        return false
    }

    // MARK: - 1:1 convenience accessors (nil when `peer` is `.group`)

    var otherUserId: String? {
        if case .direct(let id, _, _, _, _, _) = peer { return id }
        return nil
    }
    var otherUserName: String? {
        if case .direct(_, _, let name, _, _, _) = peer { return name }
        return nil
    }
    var otherUserAvatarColor: String? {
        if case .direct(_, _, _, let color, _, _) = peer { return color }
        return nil
    }
    var otherUserJobTitle: String? {
        if case .direct(_, _, _, _, let jobTitle, _) = peer { return jobTitle }
        return nil
    }
    var otherUserNickname: String? {
        if case .direct(_, _, _, _, _, let nickname) = peer { return nickname }
        return nil
    }

    // MARK: - Group convenience accessors (nil when `peer` is `.direct`)

    var groupId: String? {
        if case .group(let id, _, _, _, _, _) = peer { return id }
        return nil
    }
    var groupName: String? {
        if case .group(_, let name, _, _, _, _) = peer { return name }
        return nil
    }
    var groupAvatarUrl: String? {
        if case .group(_, _, let url, _, _, _) = peer { return url }
        return nil
    }
    var groupAvatarColor: String? {
        if case .group(_, _, _, let color, _, _) = peer { return color }
        return nil
    }
    var groupCreatedBy: String? {
        if case .group(_, _, _, _, let createdBy, _) = peer { return createdBy }
        return nil
    }
    var members: [GroupMember] {
        if case .group(_, _, _, _, _, let members) = peer { return members }
        return []
    }

    /// Name to display in the header/settings title: nickname (1:1) or group name.
    var displayName: String {
        switch peer {
        case .direct(_, _, let name, _, _, let nickname): return nickname ?? name
        case .group(_, let name, _, _, _, _): return name
        }
    }

    /// Whose initial the avatar shows: the real name, never the nickname.
    var avatarName: String {
        switch peer {
        case .direct(_, _, let name, _, _, _): return name
        case .group(_, let name, _, _, _, _): return name
        }
    }

    /// Whether the conversation is currently muted for the current user.
    var isMuted: Bool {
        guard let mutedUntil else { return false }
        return mutedUntil > Date()
    }

    /// True when muted "until turned back on" (a far-future date), as opposed
    /// to a timed mute that expires on its own.
    var isMutedIndefinitely: Bool {
        guard let mutedUntil else { return false }
        return mutedUntil > Date().addingTimeInterval(60 * 60 * 24 * 365)
    }
}

/// A single image/video item for the chat media gallery (from `GET .../media`).
struct ChatMediaItem: Identifiable, Decodable {
    let id: String
    let messageType: MessageType
    let mediaUrl: String
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case messageType = "message_type"
        case mediaUrl    = "media_url"
        case createdAt   = "created_at"
    }

    /// Absolute URL for loading the media (auth token appended for message media).
    func absoluteMediaURL() -> URL? {
        APIConfig.mediaURL(mediaUrl)
    }
}

// MARK: - Palette lookup by id (for per-conversation chat theme)

extension ThemePalette {
    /// All selectable palettes (social + work), de-duplicated.
    static let allPalettes: [ThemePalette] = [
        .sunset, .tropical, .candy, .amber, .blueShared, .rose,
        .navy, .slate, .forest, .charcoal, .deepPurple,
    ]

    /// Resolve a palette by its stored id; nil if unknown/absent.
    static func byId(_ id: String?) -> ThemePalette? {
        guard let id else { return nil }
        return allPalettes.first { $0.id == id }
    }
}

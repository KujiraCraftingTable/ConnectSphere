import SwiftUI

/// Settings snapshot for a 1-on-1 conversation (from `GET .../settings`).
/// `theme` and `otherUserNickname` are shared between both participants;
/// `mutedUntil` is the current user's own mute state.
struct ConversationSettings: Decodable {
    let theme: String?
    let mutedUntil: Date?
    let otherUserId: String
    let otherUserUsername: String?
    let otherUserName: String
    let otherUserAvatarColor: String
    let otherUserJobTitle: String?
    let otherUserNickname: String?

    enum CodingKeys: String, CodingKey {
        case theme
        case mutedUntil           = "muted_until"
        case otherUserId          = "other_user_id"
        case otherUserUsername    = "other_user_username"
        case otherUserName        = "other_user_name"
        case otherUserAvatarColor = "other_user_avatar_color"
        case otherUserJobTitle    = "other_user_job_title"
        case otherUserNickname    = "other_user_nickname"
    }

    /// Name to display for the other person: nickname takes precedence.
    var displayName: String { otherUserNickname ?? otherUserName }

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

    /// Absolute URL for loading the media.
    func absoluteMediaURL() -> URL? {
        URL(string: APIConfig.serverBase + mediaUrl)
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

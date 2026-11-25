import Foundation

/// A shared chat setting someone changed (the theme, or a nickname), shown as
/// a centered note in the timeline, like the time labels. Server migration 113.
struct ChatEvent: Decodable, Identifiable, Equatable {
    enum Kind: String, Decodable, Hashable {
        case theme, nickname, accepted, unknown

        init(from decoder: Decoder) throws {
            self = Kind(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
        }
    }

    let id: String
    let conversationId: String
    let kind: Kind
    let actorId: String
    let actorName: String
    /// `.theme`: the new theme id, nil for the default.
    let theme: String?
    /// `.nickname`: whose nickname changed, and to what (nil = cleared).
    let targetId: String?
    let targetName: String?
    let nickname: String?
    let createdAt: Date

    // MARK: - Display text
    /// "Kujira changed the theme to Amber", "You set Kujira's nickname to Bro".
    func text(currentUserId: String, bundle: Bundle) -> String {
        Self.text(kind: kind, actorId: actorId, actorName: actorName, theme: theme, targetId: targetId,
                  targetName: targetName, nickname: nickname, currentUserId: currentUserId, bundle: bundle)
    }

    /// Shared by the timeline note and the inbox preview (`Conversation.LastEvent`).
    static func text(kind: Kind, actorId: String, actorName: String, theme: String?, targetId: String?,
                     targetName: String?, nickname: String?, currentUserId: String, bundle: Bundle) -> String {
        let byMe = actorId == currentUserId
        switch kind {
        case .theme:
            guard let theme else {
                return byMe ? bundle.loc("You reset the theme")
                            : String(format: bundle.loc("%@ reset the theme"), actorName)
            }
            // An id this build doesn't know (an older app, or a hand-made
            // request) is never shown raw.
            guard let palette = ThemePalette.byId(theme) else {
                return byMe ? bundle.loc("You changed the theme")
                            : String(format: bundle.loc("%@ changed the theme"), actorName)
            }
            let name = bundle.loc(palette.name)
            return byMe ? String(format: bundle.loc("You changed the theme to %@"), name)
                        : String(format: bundle.loc("%@ changed the theme to %@"), actorName, name)
        case .accepted:
            return byMe ? bundle.loc("You accepted the message request")
                        : String(format: bundle.loc("%@ accepted your message request"), actorName)
        case .nickname, .unknown:
            let target = targetName ?? ""
            let aboutMe = targetId == currentUserId
            if let nickname {
                if byMe { return String(format: bundle.loc("You set %@'s nickname to %@"), target, nickname) }
                if aboutMe { return String(format: bundle.loc("%@ set your nickname to %@"), actorName, nickname) }
                return String(format: bundle.loc("%@ set %@'s nickname to %@"), actorName, target, nickname)
            }
            if byMe { return String(format: bundle.loc("You cleared %@'s nickname"), target) }
            if aboutMe { return String(format: bundle.loc("%@ cleared your nickname"), actorName) }
            return String(format: bundle.loc("%@ cleared %@'s nickname"), actorName, target)
        }
    }

    // MARK: - Decoding
    enum CodingKeys: String, CodingKey {
        case id, kind, theme, nickname
        case conversationId = "conversation_id"
        case actorId = "actor_id"
        case actorName = "actor_name"
        case targetId = "target_id"
        case targetName = "target_name"
        case createdAt = "created_at"
    }
}

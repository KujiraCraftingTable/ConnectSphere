import Foundation

/// A community-scoped notification for the current user
struct CommunityNotification: Identifiable, Decodable {
    let id: String
    let type: String
    let communityId: String
    let communityName: String
    let refId: String?
    let isRead: Bool
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, type
        case communityId   = "community_id"
        case communityName = "community_name"
        case refId         = "ref_id"
        case isRead        = "is_read"
        case createdAt     = "created_at"
    }

    /// Human-readable description of this notification.
    /// Dịch qua Bundle.app vì model không có @Environment(\.appBundle).
    var displayText: String {
        let b = Bundle.app
        switch type {
        case "new_post":      return String(format: b.loc("New post in %@"), communityName)
        case "pinned_post":   return String(format: b.loc("A post was pinned in %@"), communityName)
        case "join_request":  return String(format: b.loc("Someone wants to join %@"), communityName)
        case "join_approved": return String(format: b.loc("Your request to join %@ was approved"), communityName)
        case "join_rejected": return String(format: b.loc("Your request to join %@ was declined"), communityName)
        case "role_changed":  return String(format: b.loc("Your role in %@ was updated"), communityName)
        default:              return communityName
        }
    }

    /// SF Symbol name for this notification type
    var iconName: String {
        switch type {
        case "new_post":      return "doc.text"
        case "pinned_post":   return "pin.fill"
        case "join_request":  return "person.badge.plus"
        case "join_approved": return "checkmark.circle.fill"
        case "join_rejected": return "xmark.circle.fill"
        case "role_changed":  return "person.crop.circle.badge.checkmark"
        default:              return "bell"
        }
    }
}

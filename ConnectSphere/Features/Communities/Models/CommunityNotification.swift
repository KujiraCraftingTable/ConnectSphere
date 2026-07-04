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

    /// Human-readable description of this notification
    var displayText: String {
        switch type {
        case "new_post":      return "New post in \(communityName)"
        case "pinned_post":   return "A post was pinned in \(communityName)"
        case "join_request":  return "Someone wants to join \(communityName)"
        case "join_approved": return "Your request to join \(communityName) was approved"
        case "join_rejected": return "Your request to join \(communityName) was declined"
        case "role_changed":  return "Your role in \(communityName) was updated"
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

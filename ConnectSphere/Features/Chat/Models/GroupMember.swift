import Foundation

/// A participant in a group conversation — from group settings' `members` array
/// (`GET .../settings`) or the participants-management screen. Roles are a
/// simple owner/member 2-tier (not Communities' 3-tier admin/moderator/member).
struct GroupMember: Decodable, Identifiable, Equatable {
    let id: String
    let username: String
    let displayName: String
    let avatarColor: String
    let avatarUrl: String?
    /// "owner" | "member"
    let role: String
    let joinedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, username, role
        case displayName = "display_name"
        case avatarColor = "avatar_color"
        case avatarUrl   = "avatar_url"
        case joinedAt    = "joined_at"
    }

    /// True when this member currently holds the group's single owner role.
    var isOwner: Bool { role == "owner" }

    /// Absolute URL for the member's avatar photo, if set.
    func absoluteAvatarURL() -> URL? {
        APIConfig.mediaURL(avatarUrl)
    }
}

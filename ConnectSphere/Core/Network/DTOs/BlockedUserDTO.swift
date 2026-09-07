import Foundation

/// A row in the "Blocked Users" list (GET /users/blocked)
struct BlockedUserDTO: Decodable, Identifiable {
    let id: String
    let displayName: String
    let avatarColor: String?
    let avatarUrl: String?
    let blockedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case avatarColor = "avatar_color"
        case avatarUrl   = "avatar_url"
        case blockedAt   = "blocked_at"
    }
}

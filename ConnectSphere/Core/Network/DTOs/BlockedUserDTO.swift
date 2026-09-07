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

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id          = try c.decode(String.self, forKey: .id)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? "Deleted User"
        avatarColor = try c.decodeIfPresent(String.self, forKey: .avatarColor)
        avatarUrl   = try c.decodeIfPresent(String.self, forKey: .avatarUrl)
        blockedAt   = try c.decode(Date.self, forKey: .blockedAt)
    }
}

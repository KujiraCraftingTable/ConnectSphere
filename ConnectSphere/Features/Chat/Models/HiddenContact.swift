import Foundation

/// Someone hidden from the people row at the top of Messages (per mode).
/// Only the row: their chat stays in the list.
struct HiddenContact: Decodable, Identifiable, Equatable {
    let id: String
    let displayName: String
    let avatarUrl: String?
    let avatarColor: String?
    let hiddenAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case avatarUrl   = "avatar_url"
        case avatarColor = "avatar_color"
        case hiddenAt    = "hidden_at"
    }
}

extension Notification.Name {
    /// Posted after a contact is hidden or unhidden, so the Messages people row
    /// updates at once. `userInfo`: "userId" (String), "mode" (String), "hidden" (Bool).
    static let hiddenContactsChanged = Notification.Name("hiddenContactsChanged")
}

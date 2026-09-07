import Foundation

struct Community: Identifiable {
    let id: String
    let name: String
    let description: String?
    let type: CommunityType
    let privacy: CommunityPrivacy
    let iconEmoji: String
    let coverColor: String
    var memberCount: Int
    var postCount: Int
    var isMember: Bool
    var role: MemberRole?
    /// The viewer's own join-request status for this community, when they have
    /// one: "pending" | "approved" | "rejected". nil if they never requested.
    /// Only meaningful for a private community the viewer is not a member of.
    var joinRequestStatus: String?
    let createdAt: Date
}

enum CommunityType: String, CaseIterable {
    case fandom = "fandom"
    case work   = "work"

    /// Localization key — callers must wrap this in `bundle.loc(...)`. Returning
    /// a hardcoded translation here (as this used to for `.work`) meant the
    /// label showed in the wrong language regardless of the app's setting.
    var label: String {
        switch self {
        case .fandom: return "Fandom"
        case .work:   return "Work"
        }
    }

    var icon: String {
        switch self {
        case .fandom: return "star.fill"
        case .work:   return "briefcase.fill"
        }
    }
}

enum CommunityPrivacy: String {
    case `public`  = "public"
    case `private` = "private"
}

enum MemberRole: String {
    case admin     = "admin"
    case moderator = "moderator"
    case member    = "member"

    /// Localization key — callers must wrap this in `bundle.loc(...)`.
    var label: String {
        switch self {
        case .admin:     return "Admin"
        case .moderator: return "Mod"
        case .member:    return "Member"
        }
    }
}

struct CommunityMember: Identifiable {
    let id: String
    let username: String
    let displayName: String
    let avatarColor: String
    let jobTitle: String?
    let company: String?
    let role: MemberRole
    let joinedAt: Date
}

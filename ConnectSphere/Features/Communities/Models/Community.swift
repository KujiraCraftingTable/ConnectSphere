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
    let createdAt: Date
}

enum CommunityType: String, CaseIterable {
    case fandom = "fandom"
    case work   = "work"

    var label: String {
        switch self {
        case .fandom: return "Fandom"
        case .work:   return "Công việc"
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

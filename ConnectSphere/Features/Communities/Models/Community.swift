import Foundation

struct Community: Identifiable {
    let id: String
    let name: String
    let description: String?
    let type: CommunityType
    let privacy: CommunityPrivacy
    let iconEmoji: String
    let avatarUrl: String?
    /// The community's picture (no profile picture); nil → colour + emoji.
    var coverUrl: String?
    let coverColor: String
    var memberCount: Int
    var postCount: Int
    var isMember: Bool
    /// Feed-visibility mute — this community's posts are hidden from the
    /// viewer's main Feed while true, but its own page is unaffected.
    var isMuted: Bool = false
    var role: MemberRole?
    /// The viewer's own join-request status for this community, when they have
    /// one: "pending" | "approved" | "rejected". nil if they never requested.
    /// Only meaningful for a private community the viewer is not a member of.
    var joinRequestStatus: String?
    let createdAt: Date
    var nameChangedAt: Date?
    /// Members' posts wait for a moderator before going live.
    var requirePostApproval = false
    /// Pinned to the top of the viewer's My communities.
    var isPinned = false
    /// The viewer's notification level; nil when not a member.
    var notifyLevel: CommunityNotifyLevel?
}

/// Which new posts in a community notify a member.
enum CommunityNotifyLevel: String, CaseIterable {
    case all, friends, off
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

/// The "About this community" page (`GET /communities/:id/info`).
struct CommunityInfo: Decodable {
    struct Person: Decodable, Identifiable {
        let id: String
        let displayName: String
        let avatarUrl: String?
        let avatarColor: String?
        let role: String?

        enum CodingKeys: String, CodingKey {
            case id, role
            case displayName = "display_name"
            case avatarUrl = "avatar_url"
            case avatarColor = "avatar_color"
        }
    }

    let about: String?
    let privacy: String
    let createdAt: Date
    let nameChangedAt: Date?
    let memberCount: Int
    /// Your connections (in the community's mode) who joined: a few, and how many.
    let friends: [Person]
    let friendsCount: Int
    /// Admins first, then moderators.
    let staff: [Person]
    let postsToday: Int
    let postsWeek: Int
    let newMembersWeek: Int

    enum CodingKeys: String, CodingKey {
        case about, privacy, friends, staff
        case createdAt = "created_at"
        case nameChangedAt = "name_changed_at"
        case memberCount = "member_count"
        case friendsCount = "friends_count"
        case postsToday = "posts_today"
        case postsWeek = "posts_week"
        case newMembersWeek = "new_members_week"
    }
}

/// "Manage your content" (`GET /communities/:id/my-content`).
struct MyCommunityContent: Decodable {
    enum Kind: String, CaseIterable { case posts, comments }
    enum Status: String, CaseIterable { case all, published, pending, declined }

    struct Counts: Decodable, Equatable {
        let published: Int
        let pending: Int
        let declined: Int
        let comments: Int
    }

    struct Comment: Decodable, Identifiable {
        let id: String
        let content: String
        let imageUrl: String?
        let createdAt: Date
        let postId: String
        let postExcerpt: String

        enum CodingKeys: String, CodingKey {
            case id, content
            case imageUrl = "image_url"
            case createdAt = "created_at"
            case postId = "post_id"
            case postExcerpt = "post_excerpt"
        }
    }

    let counts: Counts
    let posts: [Post]
    let comments: [Comment]

    enum CodingKeys: String, CodingKey { case counts, posts, comments }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        counts = try c.decode(Counts.self, forKey: .counts)
        posts = try c.decode([PostDTO].self, forKey: .posts).map { $0.toPost() }
        comments = try c.decode([Comment].self, forKey: .comments)
    }
}

/// A community's card where it's shared: under a feed post's note.
struct SharedCommunityRef: Decodable, Equatable {
    let id: String
    let name: String
    let coverUrl: String?
    let coverColor: String
    let iconEmoji: String
    let memberCount: Int
    let privacy: String

    enum CodingKeys: String, CodingKey {
        case id, name, privacy
        case coverUrl = "cover_url"
        case coverColor = "cover_color"
        case iconEmoji = "icon_emoji"
        case memberCount = "member_count"
    }
}

/// Someone as they appear in one community
/// (`GET /communities/:id/members/:userId/profile`).
struct CommunityMemberProfile: Decodable {
    let id: String
    let username: String
    let displayName: String
    let avatarUrl: String?
    let coverUrl: String?
    let avatarColor: String?
    let connectionsCount: Int
    let role: String?
    let joinedAt: Date?
    let postCount: Int
    let posts: [Post]

    enum CodingKeys: String, CodingKey {
        case id, username, role, posts
        case displayName = "display_name"
        case avatarUrl = "avatar_url"
        case coverUrl = "cover_url"
        case avatarColor = "avatar_color"
        case connectionsCount = "connections_count"
        case joinedAt = "joined_at"
        case postCount = "post_count"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        username = try c.decode(String.self, forKey: .username)
        displayName = try c.decode(String.self, forKey: .displayName)
        avatarUrl = try c.decodeIfPresent(String.self, forKey: .avatarUrl)
        coverUrl = try c.decodeIfPresent(String.self, forKey: .coverUrl)
        avatarColor = try c.decodeIfPresent(String.self, forKey: .avatarColor)
        connectionsCount = try c.decode(Int.self, forKey: .connectionsCount)
        role = try c.decodeIfPresent(String.self, forKey: .role)
        joinedAt = try c.decodeIfPresent(Date.self, forKey: .joinedAt)
        postCount = try c.decode(Int.self, forKey: .postCount)
        posts = try c.decode([PostDTO].self, forKey: .posts).map { $0.toPost() }
    }
}

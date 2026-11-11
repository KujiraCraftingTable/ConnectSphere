import Foundation

struct Community: Identifiable {
    let id: String
    let name: String
    let description: String?
    /// 'markdown' when written with Markdown; only the detail response says (older text is plain).
    var descriptionFormat: String? = nil
    var isDescriptionMarkdown: Bool { descriptionFormat == "markdown" }
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
    /// The server's answer to "may this viewer read the posts and members"
    /// (`can_view`): also true for the official account looking into a report,
    /// read only. nil from older servers and list endpoints.
    var canView: Bool? = nil
    /// Feed-visibility mute, this community's posts are hidden from the
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
    /// Disbanded and waiting out its 7 days; only its admin still sees it.
    var disbandedAt: Date? = nil
    /// Waiting for review; filled in for admins and moderators only.
    var pendingPostCount = 0
    var pendingJoinCount = 0
    /// Reported posts and members waiting for a decision.
    var pendingReportCount = 0
    var pendingRequestCount: Int { pendingPostCount + pendingJoinCount }
    /// Everything waiting for staff: the red badge on "...".
    var staffAttentionCount: Int { pendingRequestCount + pendingReportCount }

    /// When a disbanded community is deleted for good.
    var deletionDate: Date? { disbandedAt.map { $0.addingTimeInterval(7 * 86_400) } }
}

/// Which new posts in a community notify a member.
enum CommunityNotifyLevel: String, CaseIterable {
    case all, friends, off
}

/// Communities are Hobby-only (server migration 127): a company's people
/// already talk on their own tools, so Work mode has none.
enum CommunityType: String, CaseIterable {
    case fandom = "fandom"

    /// Localization key, callers must wrap this in `bundle.loc(...)`.
    var label: String { "Fandom" }

    var icon: String { "star.fill" }
}

enum CommunityPrivacy: String {
    case `public`  = "public"
    case `private` = "private"
}

enum MemberRole: String {
    case admin     = "admin"
    case moderator = "moderator"
    case member    = "member"

    /// Localization key, callers must wrap this in `bundle.loc(...)`.
    var label: String {
        switch self {
        case .admin:     return "Admin"
        case .moderator: return "Moderator"
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
    /// Their photo in the community's mode.
    var avatarUrl: String? = nil
    /// Connected with you in the community's mode.
    var isFriend = false
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
    let aboutFormat: String?
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
        case aboutFormat = "about_format"
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

/// A community's description: up to 200 words.
enum CommunityDescription {
    static let maxWords = 200

    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }

    /// `text` cut at the 200th word, so typing past the limit just stops.
    static func clamped(_ text: String) -> String {
        guard wordCount(text) > maxWords else { return text }
        var count = 0, inWord = false
        for i in text.indices {
            let space = text[i].isWhitespace || text[i].isNewline
            if !space && !inWord {
                count += 1
                if count > maxWords { return String(text[..<i]).trimmingCharacters(in: .whitespacesAndNewlines) }
            }
            inWord = !space
        }
        return text
    }
}

extension Community {
    /// Posts and members are readable: the server says so, else member-or-public.
    var viewerCanRead: Bool { canView ?? (privacy != .private || isMember) }
    /// Reading without being a member: the official account investigating a
    /// private community. It can look, not post, join as staff or moderate.
    var isReadOnlyVisit: Bool { privacy == .private && !isMember && viewerCanRead }
}

/// Someone the admin banned: removed and kept out of the community.
struct BannedMember: Decodable, Identifiable {
    let id: String
    let username: String
    let displayName: String
    let avatarColor: String?
    let avatarUrl: String?
    let bannedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, username
        case displayName = "display_name"
        case avatarColor = "avatar_color"
        case avatarUrl = "avatar_url"
        case bannedAt = "banned_at"
    }
}

/// One line of the community's moderation log (admins and moderators).
struct ModLogEntry: Decodable, Identifiable {
    let id: String
    let action: String
    let actorName: String?
    let targetName: String?
    let postSnippet: String?
    let detail: String?
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, action, detail
        case actorName = "actor_name"
        case targetName = "target_name"
        case postSnippet = "post_snippet"
        case createdAt = "created_at"
    }
}

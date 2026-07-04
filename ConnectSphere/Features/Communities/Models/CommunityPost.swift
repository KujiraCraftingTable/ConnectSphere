import Foundation

// MARK: - Post type

enum PostType: String, Codable {
    case text  = "text"
    case poll  = "poll"
    case event = "event"
}

// MARK: - Poll

struct PollData: Codable {
    var options: [PollOption]
    var userVote: String?    // poll_option_id the user voted for; nil if not voted

    /// Total votes across all options
    var totalVotes: Int { options.reduce(0) { $0 + $1.voteCount } }
}

struct PollOption: Identifiable, Codable {
    let id: String
    let text: String
    var voteCount: Int
    let position: Int
    let endsAt: Date?

    /// Percentage of total votes this option holds (0–100)
    func percentage(totalVotes: Int) -> Double {
        guard totalVotes > 0 else { return 0 }
        return Double(voteCount) / Double(totalVotes) * 100
    }

    enum CodingKeys: String, CodingKey {
        case id, text, position
        case voteCount = "vote_count"
        case endsAt    = "ends_at"
    }
}

// MARK: - Event

struct EventData: Codable {
    let id: String
    let title: String
    let location: String?
    let startsAt: Date
    let endsAt: Date?
    var rsvpCount: Int
    var userRsvp: RsvpStatus?

    enum CodingKeys: String, CodingKey {
        case id, title, location
        case startsAt  = "starts_at"
        case endsAt    = "ends_at"
        case rsvpCount = "rsvp_count"
        case userRsvp  = "user_rsvp"
    }
}

enum RsvpStatus: String, Codable {
    case going    = "going"
    case maybe    = "maybe"
    case notGoing = "not_going"

    var label: String {
        switch self {
        case .going:    return "Going"
        case .maybe:    return "Maybe"
        case .notGoing: return "Can't go"
        }
    }

    var icon: String {
        switch self {
        case .going:    return "checkmark.circle.fill"
        case .maybe:    return "questionmark.circle.fill"
        case .notGoing: return "xmark.circle.fill"
        }
    }
}

// MARK: - Post

struct CommunityPost: Identifiable {
    let id: String
    let content: String
    let postType: PostType
    let isPinned: Bool
    let author: CommunityPostAuthor
    let community: CommunityRef?
    var likeCount: Int
    var commentCount: Int
    var isLiked: Bool
    let createdAt: Date
    var pollData: PollData?
    var eventData: EventData?
}

struct CommunityPostAuthor: Decodable {
    let id: String
    let username: String
    let displayName: String
    let avatarColor: String

    enum CodingKeys: String, CodingKey {
        case id, username
        case displayName = "display_name"
        case avatarColor = "avatar_color"
    }
}

struct CommunityRef {
    let id: String
    let name: String
    let iconEmoji: String
}

import Foundation

// MARK: - Post type

enum PostType: String, Codable {
    case text  = "text"
    case poll  = "poll"
    case event = "event"
    case job   = "job"
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

    /// Localization key — callers must wrap this in `bundle.loc(...)`.
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

// MARK: - Job

struct JobData: Codable {
    let id: String
    let title: String
    let company: String?
    let location: String?
    let employmentType: EmploymentType?
    let salaryRange: String?
    let applicationDeadline: Date?
    var interestedCount: Int
    var userInterested: Bool

    enum CodingKeys: String, CodingKey {
        case id, title, company, location
        case employmentType       = "employment_type"
        case salaryRange          = "salary_range"
        case applicationDeadline  = "application_deadline"
        case interestedCount      = "interested_count"
        case userInterested       = "user_interested"
    }
}

enum EmploymentType: String, Codable, CaseIterable {
    case fullTime   = "full_time"
    case partTime   = "part_time"
    case contract   = "contract"
    case internship = "internship"
    case remote     = "remote"

    /// Localization key — callers must wrap this in `bundle.loc(...)`.
    var label: String {
        switch self {
        case .fullTime:   return "Full-time"
        case .partTime:   return "Part-time"
        case .contract:   return "Contract"
        case .internship: return "Internship"
        case .remote:     return "Remote"
        }
    }
}

// MARK: - Post

struct CommunityPost: Identifiable {
    let id: String
    let content: String
    let postType: PostType
    var isPinned: Bool
    let author: CommunityPostAuthor
    /// `var` (not `let`) so `CommunityDetailViewModel.decodePost(_:)` can fill
    /// this in for realtime-arriving posts, whose socket payload doesn't
    /// include the joined community object `GET /communities/:id/posts` adds.
    var community: CommunityRef?
    var likeCount: Int
    var commentCount: Int
    var isLiked: Bool
    let createdAt: Date
    var pollData: PollData?
    var eventData: EventData?
    var jobData: JobData?
    /// Parity fields with Feed's `Post` — populated once `getPostsByCommunity`
    /// (backend) started reusing the shared `buildPostSelect` fragment.
    var linkUrl: String? = nil
    var imageUrl: String? = nil
    var imageUrls: [String] = []
    /// Alt text per `imageUrls` entry ('' = none).
    var imageAlts: [String] = []
    var articleTitle: String? = nil
    var tags: [String] = []

    /// Images to render in the grid — same rule as `Post.displayImageUrls`: prefer
    /// the new array; posts with a link preview don't count (that image belongs to the link card).
    /// Alt text lined up with `displayImageUrls` (the legacy single image has none).
    var displayImageAlts: [String] { imageUrls.isEmpty ? [] : imageAlts }

    var displayImageUrls: [String] {
        if !imageUrls.isEmpty { return imageUrls }
        if linkUrl == nil, let imageUrl { return [imageUrl] }
        return []
    }
}

struct CommunityPostAuthor: Decodable {
    let id: String
    let username: String
    let displayName: String
    let avatarColor: String
    var avatarUrl: String? = nil
    var jobTitle: String? = nil
    var company: String? = nil

    enum CodingKeys: String, CodingKey {
        case id, username, company
        case displayName = "display_name"
        case avatarColor = "avatar_color"
        case avatarUrl   = "avatar_url"
        case jobTitle    = "job_title"
    }
}

struct CommunityRef {
    let id: String
    let name: String
    let iconEmoji: String
    let avatarUrl: String?
}

extension CommunityPost {
    /// Adapts a just-created `CommunityPost` (what `PostComposerViewModel`'s
    /// shared submit path returns for every post type) into the Feed `Post`
    /// shape `PostCard` renders — mirrors `CreatePostView.feedPost(from:)`
    /// (same adapter need, kept separate rather than shared to avoid coupling
    /// Feed's own composer to Communities). mode/privacy come from what was
    /// just submitted (already known), not decoded from the response.
    func toPost(author: UserProfile, mode: AppMode, privacy: PostPrivacy) -> Post {
        Post(
            id:            id,
            author:        author,
            content:       content,
            timestamp:     createdAt,
            mode:          mode,
            privacy:       privacy,
            linkUrl:       linkUrl,
            imageUrl:      imageUrl,
            imageUrls:     imageUrls,
            imageAlts:     imageAlts,
            likeCount:     likeCount,
            commentCount:  commentCount,
            shareCount:    0,
            isLiked:       isLiked,
            isSaved:       false,
            articleTitle:  articleTitle,
            tags:          tags,
            sharedPostId:  nil,
            sharedPost:    nil,
            postType:      postType,
            pollData:      pollData,
            eventData:     eventData,
            jobData:       jobData,
            isPinned:      isPinned,
            pinnedAt:      nil,
            community:     community
        )
    }
}

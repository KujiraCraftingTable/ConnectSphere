import Foundation

// MARK: - Post type

enum PostType: String, Codable {
    case text  = "text"
    case poll  = "poll"
    case event = "event"
    case job   = "job"
    /// A marketplace listing. Community posts only.
    case listing = "listing"
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

    /// Localization key, callers must wrap this in `bundle.loc(...)`.
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
    /// VND million / month (Jobs-tab details).
    var salaryMin: Int? = nil
    var salaryMax: Int? = nil

    enum CodingKeys: String, CodingKey {
        case id, title, company, location
        case salaryMin            = "salary_min"
        case salaryMax            = "salary_max"
        case employmentType       = "employment_type"
        case salaryRange          = "salary_range"
        case applicationDeadline  = "application_deadline"
        case interestedCount      = "interested_count"
        case userInterested       = "user_interested"
    }
}

// MARK: - Listing

/// A marketplace listing's details. The description is the post's text and
/// the photos its images.
struct ListingData: Equatable {
    let id: String
    var title: String
    /// Whole VND; 0 = free.
    var price: Int64
    var condition: ListingCondition
    var location: String?
    var isSold: Bool
    /// How many times the seller re-upped it (0 = never).
    var reupCount: Int = 0
    var hideFromFriends: Bool
    var hasAutoReply: Bool
    /// Only filled in for the seller.
    var autoReply: String?
    /// The communities it's also showing in as a post (none = Marketplace only).
    var communities: [ListedIn] = []
    /// Where it is, picked on a map (both or neither).
    var latitude: Double? = nil
    var longitude: Double? = nil
    /// The seller's auto re-up schedule and its next run; only they get these.
    var autoReup: AutoReup? = nil
    var nextAutoReupAt: Date? = nil

    /// Posts the item again as new every `days` days at `hour`:00 Vietnam time.
    struct AutoReup: Equatable {
        var days: Int
        /// 9, 12, 15, 18, 21 or 24 (midnight).
        var hour: Int
    }

    static let autoReupDays = [1, 3, 7]
    static let autoReupHours = [9, 12, 15, 18, 21, 24]

    /// "18:00"; 24 reads as "00:00".
    static func hourLabel(_ hour: Int) -> String { String(format: "%02d:00", hour % 24) }

    static func dayLabel(_ days: Int, bundle: Bundle) -> String {
        days == 1 ? bundle.loc("1 day") : String(format: bundle.loc("%lld days"), days)
    }

    /// "Auto re-up every 3 days at 18:00".
    func autoReupText(bundle: Bundle) -> String? {
        guard let a = autoReup else { return nil }
        return a.days == 1
            ? String(format: bundle.loc("Auto re-up every day at %@"), Self.hourLabel(a.hour))
            : String(format: bundle.loc("Auto re-up every %lld days at %@"), a.days, Self.hourLabel(a.hour))
    }

    /// "Next: Thu, 9 Nov, 18:00", in Vietnam time, like the schedule itself.
    func nextAutoReupText(bundle: Bundle) -> String? {
        guard let next = nextAutoReupAt else { return nil }
        let style = Date.FormatStyle(locale: Locale(identifier: bundle.bundlePath.hasSuffix("vi.lproj") ? "vi" : "en"),
                                     timeZone: TimeZone(identifier: "Asia/Ho_Chi_Minh") ?? .current)
            .weekday(.abbreviated).day().month(.abbreviated).hour().minute()
        return String(format: bundle.loc("Next: %@"), next.formatted(style))
    }

    struct ListedIn: Equatable, Identifiable {
        let id: String
        let name: String
        let iconEmoji: String
    }

    /// "1st re-up", "2nd re-up"… / "Đăng lại lần 1"…; nil for an item never re-upped.
    func reupText(bundle: Bundle) -> String? {
        guard reupCount > 0 else { return nil }
        let vietnamese = bundle.bundlePath.hasSuffix("vi.lproj")
        return String(format: bundle.loc("%@ re-up"), vietnamese ? String(reupCount) : Self.englishOrdinal(reupCount))
    }

    /// 1st, 2nd, 3rd, 4th … 11th, 12th, 13th … 21st.
    static func englishOrdinal(_ n: Int) -> String {
        let suffix: String
        switch (n % 100, n % 10) {
        case (11...13, _): suffix = "th"
        case (_, 1): suffix = "st"
        case (_, 2): suffix = "nd"
        case (_, 3): suffix = "rd"
        default: suffix = "th"
        }
        return "\(n)\(suffix)"
    }

    /// "1.200.000 ₫", or "Free".
    func priceText(loc: (String) -> String) -> String {
        guard price > 0 else { return loc("Free") }
        return Self.priceFormatter.string(from: NSNumber(value: price)).map { $0 + " ₫" } ?? "\(price) ₫"
    }

    /// VND is written with dots between thousands, whatever the app language.
    private static let priceFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = "."
        f.usesGroupingSeparator = true
        f.maximumFractionDigits = 0
        return f
    }()
}

enum ListingCondition: String, CaseIterable {
    case new
    case likeNew = "like_new"
    case good
    case fair

    /// Localization key, callers must wrap this in `bundle.loc(...)`.
    var label: String {
        switch self {
        case .new:     return "New"
        case .likeNew: return "Used – like new"
        case .good:    return "Used – good"
        case .fair:    return "Used – fair"
        }
    }
}

enum EmploymentType: String, Codable, CaseIterable {
    case fullTime   = "full_time"
    case partTime   = "part_time"
    case contract   = "contract"
    case internship = "internship"
    case remote     = "remote"

    /// Localization key, callers must wrap this in `bundle.loc(...)`.
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
    /// Parity fields with Feed's `Post`. Populated once `getPostsByCommunity`
    /// (backend) started reusing the shared `buildPostSelect` fragment.
    var linkUrl: String? = nil
    var imageUrl: String? = nil
    var imageUrls: [String] = []
    /// Alt text per `imageUrls` entry ('' = none).
    var imageAlts: [String] = []
    /// The text's language (en / vi / other / none) and its translation into
    /// the other of en/vi, made on the server when it was published.
    var contentLang: String? = nil
    var translatedContent: String? = nil
    var contentFormat: String? = nil
    var articleTitle: String? = nil
    var tags: [String] = []
    /// "pending" while the community's admins review it.
    var publishStatus: String? = nil
    var listingData: ListingData? = nil

    /// Images to render in the grid. Same rule as `Post.displayImageUrls`: prefer
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
    /// The community's own privacy ("public" / "private").
    var privacy: String? = nil
    /// Who the post is for: anyone, or the community's members only.
    var audience: CommunityAudience = .members
}

/// Who a community post is for (migration 075). A private community's posts
/// are always `.members`.
enum CommunityAudience: String {
    case publicAll = "public"
    case members

    var label: String { self == .publicAll ? "Public" : "Community only" }
    var icon: String { self == .publicAll ? "globe.americas" : "person.2.fill" }
}

extension CommunityPost {
    /// Adapts a just-created `CommunityPost` (what `PostComposerViewModel`'s
    /// shared submit path returns for every post type) into the Feed `Post`
    /// shape `PostCard` renders. Mirrors `CreatePostView.feedPost(from:)`
    /// (same adapter need, kept separate rather than shared to avoid coupling
    /// Feed's own composer to Communities). mode/privacy come from what was
    /// just submitted (already known), not decoded from the response.
    func toPost(author: UserProfile, mode: AppMode, privacy: PostPrivacy) -> Post {
        var post = Post(
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
            contentLang:     contentLang,
            translatedContent: translatedContent,
            contentFormat: contentFormat,
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
        // The community page holds a pending post back and says it's waiting.
        post.publishStatus = publishStatus
        post.listingData = listingData
        return post
    }
}

import Foundation

// ── Community ─────────────────────────────────────────────────────────────────

struct CommunityDTO: Decodable {
    let id: String
    let name: String
    let description: String?
    let type: String
    let privacy: String
    let iconEmoji: String
    let avatarUrl: String?
    let coverUrl: String?
    let coverColor: String
    let memberCount: Int
    let postCount: Int
    let isMember: Bool
    let isMuted: Bool
    let role: String?
    let joinRequestStatus: String?
    let createdAt: Date
    let nameChangedAt: Date?
    let requirePostApproval: Bool
    let isPinned: Bool
    let notifyLevel: String?

    enum CodingKeys: String, CodingKey {
        case id, name, description, type, privacy, role
        case iconEmoji          = "icon_emoji"
        case avatarUrl          = "avatar_url"
        case coverUrl           = "cover_url"
        case nameChangedAt      = "name_changed_at"
        case requirePostApproval = "require_post_approval"
        case isPinned           = "is_pinned"
        case notifyLevel        = "notify_level"
        case coverColor         = "cover_color"
        case memberCount        = "member_count"
        case postCount          = "post_count"
        case isMember           = "is_member"
        case isMuted            = "is_muted"
        case joinRequestStatus  = "join_request_status"
        case createdAt          = "created_at"
    }

    init(from decoder: Decoder) throws {
        let c    = try decoder.container(keyedBy: CodingKeys.self)
        id          = try c.decode(String.self, forKey: .id)
        name        = try c.decode(String.self, forKey: .name)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        type        = try c.decode(String.self, forKey: .type)
        privacy     = try c.decode(String.self, forKey: .privacy)
        iconEmoji   = try c.decode(String.self, forKey: .iconEmoji)
        avatarUrl   = try c.decodeIfPresent(String.self, forKey: .avatarUrl)
        coverUrl    = try c.decodeIfPresent(String.self, forKey: .coverUrl)
        nameChangedAt = try c.decodeIfPresent(Date.self, forKey: .nameChangedAt)
        requirePostApproval = try c.decodeIfPresent(Bool.self, forKey: .requirePostApproval) ?? false
        isPinned    = try c.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        notifyLevel = try c.decodeIfPresent(String.self, forKey: .notifyLevel)
        coverColor  = try c.decode(String.self, forKey: .coverColor)
        memberCount = try c.decode(Int.self, forKey: .memberCount)
        postCount   = try c.decode(Int.self, forKey: .postCount)
        isMember    = try c.decodeIfPresent(Bool.self, forKey: .isMember) ?? false
        isMuted     = try c.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false
        role        = try c.decodeIfPresent(String.self, forKey: .role)
        joinRequestStatus = try c.decodeIfPresent(String.self, forKey: .joinRequestStatus)
        createdAt   = try c.decode(Date.self, forKey: .createdAt)
    }

    func toCommunity(isMemberOverride: Bool? = nil) -> Community {
        Community(
            id:          id,
            name:        name,
            description: description,
            type:        CommunityType(rawValue: type) ?? .fandom,
            privacy:     CommunityPrivacy(rawValue: privacy) ?? .public,
            iconEmoji:   iconEmoji,
            avatarUrl:   avatarUrl,
            coverUrl:    coverUrl,
            coverColor:  coverColor,
            memberCount: memberCount,
            postCount:   postCount,
            isMember:    isMemberOverride ?? isMember,
            isMuted:     isMuted,
            role:        role.flatMap { MemberRole(rawValue: $0) },
            joinRequestStatus: joinRequestStatus,
            createdAt:   createdAt,
            nameChangedAt: nameChangedAt,
            requirePostApproval: requirePostApproval,
            isPinned:    isPinned,
            notifyLevel: notifyLevel.flatMap { CommunityNotifyLevel(rawValue: $0) }
        )
    }
}

// ── Member ────────────────────────────────────────────────────────────────────

struct CommunityMemberDTO: Decodable {
    let id: String
    let username: String
    let displayName: String
    let avatarColor: String
    let jobTitle: String?
    let company: String?
    let role: String
    let joinedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, username, role, company
        case displayName = "display_name"
        case avatarColor = "avatar_color"
        case jobTitle    = "job_title"
        case joinedAt    = "joined_at"
    }

    func toMember() -> CommunityMember {
        CommunityMember(
            id:          id,
            username:    username,
            displayName: displayName,
            avatarColor: avatarColor,
            jobTitle:    jobTitle,
            company:     company,
            role:        MemberRole(rawValue: role) ?? .member,
            joinedAt:    joinedAt
        )
    }
}

// ── Post ──────────────────────────────────────────────────────────────────────

struct CommunityPostDTO: Decodable {
    let id: String
    let content: String
    let postType: String
    let isPinned: Bool
    let likeCount: Int
    let commentCount: Int
    let isLiked: Bool
    let createdAt: Date
    let author: CommunityPostAuthorDTO
    let community: CommunityRefDTO?
    let pollData: PollDataDTO?
    let eventData: EventDataDTO?
    let jobData: JobDataDTO?
    // Parity fields — same shape as Feed's PostDTO now that
    // getPostsByCommunity reuses the shared buildPostSelect fragment.
    let imageUrl: String?
    let imageUrls: [String]?
    let imageAlts: [String]?
    let lang: String?
    let translatedText: String?
    let linkUrl: String?
    let articleTitle: String?
    let tags: [String]?

    enum CodingKeys: String, CodingKey {
        case id, content, author, community, tags
        case postType     = "post_type"
        case isPinned     = "is_pinned"
        case likeCount    = "like_count"
        case commentCount = "comment_count"
        case isLiked      = "is_liked"
        case createdAt    = "created_at"
        case pollData     = "poll_data"
        case eventData    = "event_data"
        case jobData      = "job_data"
        case imageUrl     = "image_url"
        case imageUrls    = "image_urls"
        case imageAlts    = "image_alts"
        case lang
        case translatedText    = "translated_text"
        case linkUrl      = "link_url"
        case articleTitle = "article_title"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id           = try c.decode(String.self, forKey: .id)
        content      = try c.decode(String.self, forKey: .content)
        postType     = try c.decodeIfPresent(String.self, forKey: .postType) ?? "text"
        isPinned     = try c.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        likeCount    = try c.decode(Int.self, forKey: .likeCount)
        commentCount = try c.decode(Int.self, forKey: .commentCount)
        isLiked      = try c.decodeIfPresent(Bool.self, forKey: .isLiked) ?? false
        createdAt    = try c.decode(Date.self, forKey: .createdAt)
        author       = try c.decode(CommunityPostAuthorDTO.self, forKey: .author)
        community    = try c.decodeIfPresent(CommunityRefDTO.self, forKey: .community)
        pollData     = try c.decodeIfPresent(PollDataDTO.self, forKey: .pollData)
        eventData    = try c.decodeIfPresent(EventDataDTO.self, forKey: .eventData)
        jobData      = try c.decodeIfPresent(JobDataDTO.self, forKey: .jobData)
        imageUrl     = try c.decodeIfPresent(String.self, forKey: .imageUrl)
        imageUrls    = try c.decodeIfPresent([String].self, forKey: .imageUrls)
        imageAlts    = try c.decodeIfPresent([String].self, forKey: .imageAlts)
        lang    = try c.decodeIfPresent(String.self, forKey: .lang)
        translatedText = try c.decodeIfPresent(String.self, forKey: .translatedText)
        linkUrl      = try c.decodeIfPresent(String.self, forKey: .linkUrl)
        articleTitle = try c.decodeIfPresent(String.self, forKey: .articleTitle)
        tags         = try c.decodeIfPresent([String].self, forKey: .tags)
    }

    func toCommunityPost() -> CommunityPost {
        CommunityPost(
            id:           id,
            content:      content,
            postType:     PostType(rawValue: postType) ?? .text,
            isPinned:     isPinned,
            author:       author.toAuthor(),
            community:    community?.toCommunityRef(),
            likeCount:    likeCount,
            commentCount: commentCount,
            isLiked:      isLiked,
            createdAt:    createdAt,
            pollData:     pollData?.toPollData(),
            eventData:    eventData?.toEventData(),
            jobData:      jobData?.toJobData(),
            linkUrl:      linkUrl,
            imageUrl:     imageUrl,
            imageUrls:    imageUrls ?? [],
            imageAlts:    imageAlts ?? [],
            contentLang:    lang,
            translatedContent: translatedText,
            articleTitle: articleTitle,
            tags:         tags ?? []
        )
    }
}

struct CommunityPostAuthorDTO: Decodable {
    let id: String
    let username: String
    let displayName: String
    let avatarColor: String
    let avatarUrl: String?
    let jobTitle: String?
    let company: String?

    enum CodingKeys: String, CodingKey {
        case id, username, company
        case displayName = "display_name"
        case avatarColor = "avatar_color"
        case avatarUrl   = "avatar_url"
        case jobTitle    = "job_title"
    }

    func toAuthor() -> CommunityPostAuthor {
        CommunityPostAuthor(
            id: id, username: username, displayName: displayName, avatarColor: avatarColor,
            avatarUrl: avatarUrl, jobTitle: jobTitle, company: company
        )
    }
}

struct CommunityRefDTO: Decodable {
    let id: String
    let name: String
    let iconEmoji: String
    let avatarUrl: String?

    enum CodingKeys: String, CodingKey {
        case id, name
        case iconEmoji = "icon_emoji"
        case avatarUrl = "avatar_url"
    }

    func toCommunityRef() -> CommunityRef {
        CommunityRef(id: id, name: name, iconEmoji: iconEmoji, avatarUrl: avatarUrl)
    }
}

// ── Poll DTOs ─────────────────────────────────────────────────────────────────

struct PollDataDTO: Decodable {
    let options: [PollOptionDTO]
    let userVote: String?

    enum CodingKeys: String, CodingKey {
        case options
        case userVote = "user_vote"
    }

    // Defensive: a poll payload with a missing/garbled `options` array must not
    // fail the whole feed page — decode to [] and let the card render empty.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        options  = try c.decodeIfPresent([PollOptionDTO].self, forKey: .options) ?? []
        userVote = try c.decodeIfPresent(String.self, forKey: .userVote)
    }

    func toPollData() -> PollData {
        PollData(options: options.map { $0.toPollOption() }, userVote: userVote)
    }
}

struct PollOptionDTO: Decodable {
    let id: String
    let text: String
    let voteCount: Int
    let position: Int
    let endsAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, text, position
        case voteCount = "vote_count"
        case endsAt    = "ends_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id        = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        text      = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        voteCount = try c.decodeIfPresent(Int.self, forKey: .voteCount) ?? 0
        position  = try c.decodeIfPresent(Int.self, forKey: .position) ?? 0
        endsAt    = try c.decodeIfPresent(Date.self, forKey: .endsAt)
    }

    func toPollOption() -> PollOption {
        PollOption(id: id, text: text, voteCount: voteCount, position: position, endsAt: endsAt)
    }
}

// ── Event DTOs ────────────────────────────────────────────────────────────────

struct EventDataDTO: Decodable {
    let id: String
    let title: String
    let location: String?
    let startsAt: Date
    let endsAt: Date?
    let rsvpCount: Int
    let userRsvp: String?

    enum CodingKeys: String, CodingKey {
        case id, title, location
        case startsAt  = "starts_at"
        case endsAt    = "ends_at"
        case rsvpCount = "rsvp_count"
        case userRsvp  = "user_rsvp"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id        = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        title     = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        location  = try c.decodeIfPresent(String.self, forKey: .location)
        startsAt  = (try? c.decode(Date.self, forKey: .startsAt)) ?? .distantPast
        endsAt    = try c.decodeIfPresent(Date.self, forKey: .endsAt)
        rsvpCount = try c.decodeIfPresent(Int.self, forKey: .rsvpCount) ?? 0
        userRsvp  = try c.decodeIfPresent(String.self, forKey: .userRsvp)
    }

    func toEventData() -> EventData {
        EventData(
            id:        id,
            title:     title,
            location:  location,
            startsAt:  startsAt,
            endsAt:    endsAt,
            rsvpCount: rsvpCount,
            userRsvp:  userRsvp.flatMap { RsvpStatus(rawValue: $0) }
        )
    }
}

// ── Job DTOs ──────────────────────────────────────────────────────────────────

struct JobDataDTO: Decodable {
    let id: String
    let title: String
    let company: String?
    let location: String?
    let employmentType: String?
    let salaryRange: String?
    let applicationDeadline: Date?
    let interestedCount: Int
    let userInterested: Bool
    let salaryMin: Int?
    let salaryMax: Int?

    enum CodingKeys: String, CodingKey {
        case id, title, company, location
        case salaryMin           = "salary_min"
        case salaryMax           = "salary_max"
        case employmentType      = "employment_type"
        case salaryRange         = "salary_range"
        case applicationDeadline = "application_deadline"
        case interestedCount     = "interested_count"
        case userInterested      = "user_interested"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id                  = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        title               = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        company             = try c.decodeIfPresent(String.self, forKey: .company)
        location            = try c.decodeIfPresent(String.self, forKey: .location)
        employmentType      = try c.decodeIfPresent(String.self, forKey: .employmentType)
        salaryRange         = try c.decodeIfPresent(String.self, forKey: .salaryRange)
        applicationDeadline = try c.decodeIfPresent(Date.self, forKey: .applicationDeadline)
        interestedCount     = try c.decodeIfPresent(Int.self, forKey: .interestedCount) ?? 0
        userInterested      = try c.decodeIfPresent(Bool.self, forKey: .userInterested) ?? false
        salaryMin           = try c.decodeIfPresent(Int.self, forKey: .salaryMin)
        salaryMax           = try c.decodeIfPresent(Int.self, forKey: .salaryMax)
    }

    func toJobData() -> JobData {
        JobData(
            id:                  id,
            title:               title,
            company:             company,
            location:            location,
            employmentType:      employmentType.flatMap { EmploymentType(rawValue: $0) },
            salaryRange:         salaryRange,
            applicationDeadline: applicationDeadline,
            interestedCount:     interestedCount,
            userInterested:      userInterested,
            salaryMin:           salaryMin,
            salaryMax:           salaryMax
        )
    }
}

// ── Join Request DTO ──────────────────────────────────────────────────────────

/// Flat row returned by GET /api/communities/:id/join-requests
struct JoinRequestDTO: Decodable {
    let id: String
    let requestedAt: Date
    let status: String
    let userId: String
    let username: String
    let displayName: String
    let avatarColor: String

    enum CodingKeys: String, CodingKey {
        case id, status, username
        case requestedAt = "requested_at"
        case userId      = "user_id"
        case displayName = "display_name"
        case avatarColor = "avatar_color"
    }

    func toJoinRequest() -> JoinRequest {
        JoinRequest(
            id:          id,
            user:        JoinRequestUser(id: userId, username: username, displayName: displayName, avatarColor: avatarColor),
            requestedAt: requestedAt,
            status:      status
        )
    }
}

// ── Misc response types ───────────────────────────────────────────────────────

struct UnreadCountResponse: Decodable {
    let count: Int
}

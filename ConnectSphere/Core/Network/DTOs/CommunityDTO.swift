import Foundation

// ── Community ─────────────────────────────────────────────────────────────────

struct CommunityDTO: Decodable {
    let id: String
    let name: String
    let description: String?
    let type: String
    let privacy: String
    let iconEmoji: String
    let coverColor: String
    let memberCount: Int
    let postCount: Int
    let isMember: Bool
    let role: String?
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, name, description, type, privacy, role
        case iconEmoji   = "icon_emoji"
        case coverColor  = "cover_color"
        case memberCount = "member_count"
        case postCount   = "post_count"
        case isMember    = "is_member"
        case createdAt   = "created_at"
    }

    init(from decoder: Decoder) throws {
        let c    = try decoder.container(keyedBy: CodingKeys.self)
        id          = try c.decode(String.self, forKey: .id)
        name        = try c.decode(String.self, forKey: .name)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        type        = try c.decode(String.self, forKey: .type)
        privacy     = try c.decode(String.self, forKey: .privacy)
        iconEmoji   = try c.decode(String.self, forKey: .iconEmoji)
        coverColor  = try c.decode(String.self, forKey: .coverColor)
        memberCount = try c.decode(Int.self, forKey: .memberCount)
        postCount   = try c.decode(Int.self, forKey: .postCount)
        isMember    = try c.decodeIfPresent(Bool.self, forKey: .isMember) ?? false
        role        = try c.decodeIfPresent(String.self, forKey: .role)
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
            coverColor:  coverColor,
            memberCount: memberCount,
            postCount:   postCount,
            isMember:    isMemberOverride ?? isMember,
            role:        role.flatMap { MemberRole(rawValue: $0) },
            createdAt:   createdAt
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

    enum CodingKeys: String, CodingKey {
        case id, content, author, community
        case postType     = "post_type"
        case isPinned     = "is_pinned"
        case likeCount    = "like_count"
        case commentCount = "comment_count"
        case isLiked      = "is_liked"
        case createdAt    = "created_at"
        case pollData     = "poll_data"
        case eventData    = "event_data"
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
            eventData:    eventData?.toEventData()
        )
    }
}

struct CommunityPostAuthorDTO: Decodable {
    let id: String
    let username: String
    let displayName: String
    let avatarColor: String

    enum CodingKeys: String, CodingKey {
        case id, username
        case displayName = "display_name"
        case avatarColor = "avatar_color"
    }

    func toAuthor() -> CommunityPostAuthor {
        CommunityPostAuthor(id: id, username: username, displayName: displayName, avatarColor: avatarColor)
    }
}

struct CommunityRefDTO: Decodable {
    let id: String
    let name: String
    let iconEmoji: String

    enum CodingKeys: String, CodingKey {
        case id, name
        case iconEmoji = "icon_emoji"
    }

    func toCommunityRef() -> CommunityRef {
        CommunityRef(id: id, name: name, iconEmoji: iconEmoji)
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

import Foundation

struct PostAuthorDTO: Decodable {
    let id: String
    let username: String
    let displayName: String
    let avatarColor: String
    let avatarUrl: String?
    let jobTitle: String?
    let company: String?
    let isOfficial: Bool

    enum CodingKeys: String, CodingKey {
        case id, username, company
        case isOfficial  = "is_official"
        case displayName = "display_name"
        case avatarColor = "avatar_color"
        case avatarUrl   = "avatar_url"
        case jobTitle    = "job_title"
    }

    // A post/comment by a deleted account comes back with null identity fields.
    // Decode leniently so one such row never fails the whole list payload.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id          = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        username    = try c.decodeIfPresent(String.self, forKey: .username) ?? "deleted"
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? "Deleted User"
        avatarColor = try c.decodeIfPresent(String.self, forKey: .avatarColor) ?? "#9E9E9E"
        avatarUrl   = try c.decodeIfPresent(String.self, forKey: .avatarUrl)
        jobTitle    = try c.decodeIfPresent(String.self, forKey: .jobTitle)
        company     = try c.decodeIfPresent(String.self, forKey: .company)
        isOfficial  = try c.decodeIfPresent(Bool.self, forKey: .isOfficial) ?? false
    }

    /// Fallback for a post/comment whose `author` object is entirely absent.
    static let deleted = PostAuthorDTO(
        id: "", username: "deleted", displayName: "Deleted User",
        avatarColor: "#9E9E9E", avatarUrl: nil, jobTitle: nil, company: nil
    )

    private init(id: String, username: String, displayName: String, avatarColor: String,
                 avatarUrl: String?, jobTitle: String?, company: String?) {
        self.id = id; self.username = username; self.displayName = displayName
        self.avatarColor = avatarColor; self.avatarUrl = avatarUrl
        self.jobTitle = jobTitle; self.company = company; self.isOfficial = false
    }

    func toUserProfile() -> UserProfile {
        UserProfile(
            id:             id,
            name:           displayName,
            username:       username,
            avatarColor:    avatarColor,
            avatarUrl:      avatarUrl,
            bio:            "",
            jobTitle:       jobTitle,
            company:        company,
            skills:         [],
            interests:      [],
            location:       nil,
            followerCount:  0,
            followingCount: 0,
            postCount:      0,
            isOfficial:     isOfficial
        )
    }
}

/// The original post embedded in a shared post (backend nests it under shared_post)
struct SharedPostDTO: Decodable {
    let id: String
    let content: String?
    let imageUrl: String?
    let imageUrls: [String]?
    let imageAlts: [String]?
    let lang: String?
    let translatedText: String?
    let contentFormat: String?
    let linkUrl: String?
    let articleTitle: String?
    let createdAt: Date
    let author: PostAuthorDTO

    enum CodingKeys: String, CodingKey {
        case id, content, author
        case imageUrl     = "image_url"
        case imageUrls    = "image_urls"
        case imageAlts    = "image_alts"
        case lang
        case translatedText    = "translated_text"
        case contentFormat     = "content_format"
        case linkUrl      = "link_url"
        case articleTitle = "article_title"
        case createdAt    = "created_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id           = try c.decode(String.self, forKey: .id)
        content      = try c.decodeIfPresent(String.self, forKey: .content)
        imageUrl     = try c.decodeIfPresent(String.self, forKey: .imageUrl)
        imageUrls    = try c.decodeIfPresent([String].self, forKey: .imageUrls)
        imageAlts    = try c.decodeIfPresent([String].self, forKey: .imageAlts)
        lang    = try c.decodeIfPresent(String.self, forKey: .lang)
        translatedText = try c.decodeIfPresent(String.self, forKey: .translatedText)
        contentFormat = try c.decodeIfPresent(String.self, forKey: .contentFormat)
        linkUrl      = try c.decodeIfPresent(String.self, forKey: .linkUrl)
        articleTitle = try c.decodeIfPresent(String.self, forKey: .articleTitle)
        createdAt    = (try? c.decode(Date.self, forKey: .createdAt)) ?? Date()
        author       = try c.decodeIfPresent(PostAuthorDTO.self, forKey: .author) ?? .deleted
    }

    func toPreview() -> SharedPostPreview {
        SharedPostPreview(
            id:           id,
            author:       author.toUserProfile(),
            content:      content ?? "",
            imageUrl:     imageUrl,
            imageUrls:    imageUrls ?? [],
            imageAlts:    imageAlts ?? [],
            contentLang:    lang,
            translatedContent: translatedText,
            contentFormat: contentFormat,
            linkUrl:      linkUrl,
            articleTitle: articleTitle,
            timestamp:    createdAt
        )
    }
}

struct PostDTO: Decodable {
    let id: String
    let content: String
    let mode: String
    let privacy: String
    let imageUrl: String?
    let imageUrls: [String]?
    let imageAlts: [String]?
    let lang: String?
    let translatedText: String?
    let contentFormat: String?
    let articleTitle: String?
    let linkUrl: String?
    let isLiked: Bool
    let isSaved: Bool
    let likeCount: Int
    let commentCount: Int
    let shareCount: Int
    let createdAt: Date
    let editedAt: Date?
    let tags: [String]
    let author: PostAuthorDTO
    let sharedPostId: String?
    let sharedPost: SharedPostDTO?
    let sharedCommunity: SharedCommunityRef?
    let postType: String
    let pollData: PollDataDTO?
    let eventData: EventDataDTO?
    let jobData: JobDataDTO?
    let listingData: ListingDataDTO?
    let isPinned: Bool
    let pinnedAt: Date?
    let community: CommunityRefDTO?
    let status: String?
    let publishAt: Date?
    let declineReason: String?

    enum CodingKeys: String, CodingKey {
        case id, content, mode, privacy, tags, author
        case imageUrl      = "image_url"
        case imageUrls     = "image_urls"
        case imageAlts     = "image_alts"
        case lang
        case translatedText     = "translated_text"
        case contentFormat      = "content_format"
        case articleTitle  = "article_title"
        case linkUrl       = "link_url"
        case isLiked       = "is_liked"
        case isSaved       = "is_saved"
        case likeCount     = "like_count"
        case commentCount  = "comment_count"
        case shareCount    = "share_count"
        case createdAt     = "created_at"
        case editedAt      = "edited_at"
        case sharedPostId  = "shared_post_id"
        case sharedPost    = "shared_post"
        case sharedCommunity = "shared_community"
        case postType      = "post_type"
        case pollData      = "poll_data"
        case eventData     = "event_data"
        case jobData       = "job_data"
        case listingData   = "listing_data"
        case isPinned      = "is_pinned"
        case pinnedAt      = "pinned_at"
        case community, status
        case publishAt = "publish_at"
        case declineReason = "decline_reason"
    }

    // Custom init (instead of synthesized) so isSaved/postType/pollData/
    // eventData all get backward-compat defaults via decodeIfPresent,
    // mirrors CommunityPostDTO's existing pattern, so responses from before
    // the backend added these fields still decode.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id            = try c.decode(String.self, forKey: .id)
        content       = try c.decodeIfPresent(String.self, forKey: .content) ?? ""
        mode          = try c.decodeIfPresent(String.self, forKey: .mode) ?? "hobby"
        privacy       = try c.decodeIfPresent(String.self, forKey: .privacy) ?? "public"
        imageUrl      = try c.decodeIfPresent(String.self, forKey: .imageUrl)
        imageUrls     = try c.decodeIfPresent([String].self, forKey: .imageUrls)
        imageAlts     = try c.decodeIfPresent([String].self, forKey: .imageAlts)
        lang     = try c.decodeIfPresent(String.self, forKey: .lang)
        translatedText = try c.decodeIfPresent(String.self, forKey: .translatedText)
        contentFormat = try c.decodeIfPresent(String.self, forKey: .contentFormat)
        articleTitle  = try c.decodeIfPresent(String.self, forKey: .articleTitle)
        linkUrl       = try c.decodeIfPresent(String.self, forKey: .linkUrl)
        isLiked       = try c.decodeIfPresent(Bool.self, forKey: .isLiked) ?? false
        isSaved       = try c.decodeIfPresent(Bool.self, forKey: .isSaved) ?? false
        likeCount     = try c.decodeIfPresent(Int.self, forKey: .likeCount) ?? 0
        commentCount  = try c.decodeIfPresent(Int.self, forKey: .commentCount) ?? 0
        shareCount    = try c.decodeIfPresent(Int.self, forKey: .shareCount) ?? 0
        // A malformed / missing `created_at` must not fail the whole list page,
        // fall back to .distantPast so the row sorts to the bottom instead.
        createdAt     = (try? c.decode(Date.self, forKey: .createdAt)) ?? .distantPast
        editedAt      = try? c.decodeIfPresent(Date.self, forKey: .editedAt)
        tags          = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        author        = try c.decodeIfPresent(PostAuthorDTO.self, forKey: .author) ?? .deleted
        sharedPostId  = try c.decodeIfPresent(String.self, forKey: .sharedPostId)
        sharedPost    = try c.decodeIfPresent(SharedPostDTO.self, forKey: .sharedPost)
        sharedCommunity = try? c.decodeIfPresent(SharedCommunityRef.self, forKey: .sharedCommunity)
        postType      = try c.decodeIfPresent(String.self, forKey: .postType) ?? "text"
        pollData      = try c.decodeIfPresent(PollDataDTO.self, forKey: .pollData)
        eventData     = try c.decodeIfPresent(EventDataDTO.self, forKey: .eventData)
        jobData       = try c.decodeIfPresent(JobDataDTO.self, forKey: .jobData)
        listingData   = try c.decodeIfPresent(ListingDataDTO.self, forKey: .listingData)
        isPinned      = try c.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        pinnedAt      = try c.decodeIfPresent(Date.self, forKey: .pinnedAt)
        community     = try c.decodeIfPresent(CommunityRefDTO.self, forKey: .community)
        status        = try c.decodeIfPresent(String.self, forKey: .status)
        publishAt     = try? c.decodeIfPresent(Date.self, forKey: .publishAt)
        declineReason = try c.decodeIfPresent(String.self, forKey: .declineReason)
    }

    func toPost() -> Post {
        Post(
            id:                     id,
            author:                 author.toUserProfile(),
            content:                content,
            timestamp:              createdAt,
            editedAt:               editedAt,
            mode:                   mode == "work" ? .work : .hobby,
            privacy:                PostPrivacy(rawValue: privacy) ?? .publicAll,
            linkUrl:                linkUrl,
            imageUrl:               imageUrl,
            imageUrls:              imageUrls ?? [],
            imageAlts:              imageAlts ?? [],
            contentLang:              lang,
            translatedContent: translatedText,
            contentFormat: contentFormat,
            likeCount:              likeCount,
            commentCount:           commentCount,
            shareCount:             shareCount,
            isLiked:                isLiked,
            isSaved:                isSaved,
            articleTitle:           articleTitle,
            tags:                   tags,
            sharedPostId:           sharedPostId,
            sharedPost:             sharedPost?.toPreview(),
            sharedCommunity:        sharedCommunity,
            postType:               PostType(rawValue: postType) ?? .text,
            pollData:               pollData?.toPollData(),
            eventData:              eventData?.toEventData(),
            jobData:                jobData?.toJobData(),
            listingData:            listingData?.toListingData(),
            isPinned:               isPinned,
            pinnedAt:               pinnedAt,
            community:              community?.toCommunityRef(),
            publishStatus:          status,
            publishAt:              publishAt,
            declineReason:          declineReason
        )
    }
}

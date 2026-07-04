import Foundation

struct PostAuthorDTO: Decodable {
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
            postCount:      0
        )
    }
}

/// Bài gốc nhúng trong bài share (backend trả lồng trong shared_post)
struct SharedPostDTO: Decodable {
    let id: String
    let content: String?
    let imageUrl: String?
    let imageUrls: [String]?
    let linkUrl: String?
    let articleTitle: String?
    let createdAt: Date
    let author: PostAuthorDTO

    enum CodingKeys: String, CodingKey {
        case id, content, author
        case imageUrl     = "image_url"
        case imageUrls    = "image_urls"
        case linkUrl      = "link_url"
        case articleTitle = "article_title"
        case createdAt    = "created_at"
    }

    func toPreview() -> SharedPostPreview {
        SharedPostPreview(
            id:           id,
            author:       author.toUserProfile(),
            content:      content ?? "",
            imageUrl:     imageUrl,
            imageUrls:    imageUrls ?? [],
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
    let articleTitle: String?
    let linkUrl: String?
    let isLiked: Bool
    let likeCount: Int
    let commentCount: Int
    let shareCount: Int
    let createdAt: Date
    let tags: [String]
    let author: PostAuthorDTO
    let sharedPostId: String?
    let sharedPost: SharedPostDTO?

    enum CodingKeys: String, CodingKey {
        case id, content, mode, privacy, tags, author
        case imageUrl      = "image_url"
        case imageUrls     = "image_urls"
        case articleTitle  = "article_title"
        case linkUrl       = "link_url"
        case isLiked       = "is_liked"
        case likeCount     = "like_count"
        case commentCount  = "comment_count"
        case shareCount    = "share_count"
        case createdAt     = "created_at"
        case sharedPostId  = "shared_post_id"
        case sharedPost    = "shared_post"
    }

    func toPost() -> Post {
        Post(
            id:                     id,
            author:                 author.toUserProfile(),
            content:                content,
            imagePlaceholderColor:  nil,
            timestamp:              createdAt,
            mode:                   mode == "colleague" ? .colleague : .friend,
            privacy:                PostPrivacy(rawValue: privacy) ?? .publicAll,
            linkUrl:                linkUrl,
            imageUrl:               imageUrl,
            imageUrls:              imageUrls ?? [],
            likeCount:              likeCount,
            commentCount:           commentCount,
            shareCount:             shareCount,
            isLiked:                isLiked,
            articleTitle:           articleTitle,
            tags:                   tags,
            sharedPostId:           sharedPostId,
            sharedPost:             sharedPost?.toPreview()
        )
    }
}

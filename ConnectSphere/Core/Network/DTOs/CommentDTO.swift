import Foundation

struct CommentAuthorDTO: Decodable {
    let id: String
    let displayName: String
    let avatarColor: String
    let avatarUrl: String?

    enum CodingKeys: String, CodingKey {
        case id
        case avatarColor = "avatar_color"
        case avatarUrl   = "avatar_url"
        case displayName = "display_name"
    }

    // Comment by a deleted account → null identity fields; decode leniently.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id          = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? "Deleted User"
        avatarColor = try c.decodeIfPresent(String.self, forKey: .avatarColor) ?? "#9E9E9E"
        avatarUrl   = try c.decodeIfPresent(String.self, forKey: .avatarUrl)
    }

    static let deleted = CommentAuthorDTO()
    private init() {
        id = ""; displayName = "Deleted User"; avatarColor = "#9E9E9E"; avatarUrl = nil
    }
}

struct CommentDTO: Decodable, Identifiable {
    let id: String
    let content: String
    let createdAt: Date
    let parentCommentId: String?
    var likeCount: Int
    var isLiked: Bool
    let author: CommentAuthorDTO

    enum CodingKeys: String, CodingKey {
        case id, content, author
        case createdAt       = "created_at"
        case parentCommentId = "parent_comment_id"
        case likeCount       = "like_count"
        case isLiked         = "is_liked"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id              = try c.decode(String.self, forKey: .id)
        content         = try c.decodeIfPresent(String.self, forKey: .content) ?? ""
        createdAt       = try c.decode(Date.self, forKey: .createdAt)
        parentCommentId = try c.decodeIfPresent(String.self, forKey: .parentCommentId)
        likeCount       = try c.decodeIfPresent(Int.self, forKey: .likeCount) ?? 0
        isLiked         = try c.decodeIfPresent(Bool.self, forKey: .isLiked) ?? false
        author          = try c.decodeIfPresent(CommentAuthorDTO.self, forKey: .author) ?? .deleted
    }
}

struct CommentsResponse: Decodable {
    let data:  [CommentDTO]
    let total: Int
}

/// One of the current user's own soft-deleted comments — shape returned by
/// `GET /posts/comments/deleted` (no `author`; the "Recently Deleted" screen
/// only ever lists the viewer's own comments, so it's always "you").
struct DeletedComment: Decodable, Identifiable {
    let id: String
    let postId: String
    let content: String
    let createdAt: Date
    let deletedAt: Date
    let parentCommentId: String?
    let likeCount: Int

    enum CodingKeys: String, CodingKey {
        case id, content
        case postId          = "post_id"
        case createdAt       = "created_at"
        case deletedAt       = "deleted_at"
        case parentCommentId = "parent_comment_id"
        case likeCount       = "like_count"
    }
}

struct LikeResponse: Decodable {
    let liked:     Bool
    let likeCount: Int
    enum CodingKeys: String, CodingKey {
        case liked, likeCount = "like_count"
    }
}

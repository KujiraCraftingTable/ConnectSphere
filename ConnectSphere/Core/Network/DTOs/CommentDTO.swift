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
}

struct CommentsResponse: Decodable {
    let data:  [CommentDTO]
    let total: Int
}

struct LikeResponse: Decodable {
    let liked:     Bool
    let likeCount: Int
    enum CodingKeys: String, CodingKey {
        case liked, likeCount = "like_count"
    }
}

import Foundation

/// Whose edit history to load: a post, or one comment on a post.
enum EditHistorySubject: Hashable, Identifiable {
    case post(id: String)
    case comment(postId: String, commentId: String)

    var id: String {
        switch self {
        case .post(let id): return "post-\(id)"
        case .comment(_, let commentId): return "comment-\(commentId)"
        }
    }
}

/// One earlier version of a post or comment. `replacedAt` is when an edit
/// replaced it. Comments carry at most one photo; posts carry several.
struct EditRevisionDTO: Decodable, Identifiable {
    let id: String
    let content: String
    let contentFormat: String
    let imageUrls: [String]
    let articleTitle: String?
    let linkUrl: String?
    let replacedAt: Date

    var isMarkdown: Bool { contentFormat == "markdown" }

    enum CodingKeys: String, CodingKey {
        case id, content
        case contentFormat = "content_format"
        case imageUrls     = "image_urls"
        case imageUrl      = "image_url"
        case articleTitle  = "article_title"
        case linkUrl       = "link_url"
        case replacedAt    = "created_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id            = try c.decode(String.self, forKey: .id)
        content       = try c.decodeIfPresent(String.self, forKey: .content) ?? ""
        contentFormat = try c.decodeIfPresent(String.self, forKey: .contentFormat) ?? "plain"
        let single    = try c.decodeIfPresent(String.self, forKey: .imageUrl)
        imageUrls     = try c.decodeIfPresent([String].self, forKey: .imageUrls) ?? (single.map { [$0] } ?? [])
        articleTitle  = try c.decodeIfPresent(String.self, forKey: .articleTitle)
        linkUrl       = try c.decodeIfPresent(String.self, forKey: .linkUrl)
        replacedAt    = try c.decode(Date.self, forKey: .replacedAt)
    }
}

/// Loads the earlier versions of posts and comments, newest first.
struct EditHistoryRepository {
    private let client = NetworkClient.shared

    func fetch(_ subject: EditHistorySubject) async throws -> [EditRevisionDTO] {
        guard let token = KeychainHelper.load(forKey: KeychainHelper.tokenKey) else {
            throw APIError.serverError(statusCode: 401, message: "Not authenticated")
        }
        let path: String
        switch subject {
        case .post(let id): path = "/posts/\(id)/history"
        case .comment(let postId, let commentId): path = "/posts/\(postId)/comments/\(commentId)/history"
        }
        struct Response: Decodable { let data: [EditRevisionDTO] }
        return try await client.fetch(Response.self, path: path, method: "GET", token: token).data
    }
}

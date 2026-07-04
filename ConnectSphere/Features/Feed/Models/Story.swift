import Foundation

/// Một story 24h (backend trả flat list, client group theo author)
struct StoryDTO: Decodable, Identifiable {
    let id: String
    let authorId: String
    let imageUrl: String
    let createdAt: Date
    let expiresAt: Date
    let viewed: Bool
    let author: PostAuthorDTO

    enum CodingKeys: String, CodingKey {
        case id, viewed, author
        case authorId  = "author_id"
        case imageUrl  = "image_url"
        case createdAt = "created_at"
        case expiresAt = "expires_at"
    }
}

/// Stories của một người, dùng cho bubble + viewer
struct StoryGroup: Identifiable {
    let author: UserProfile
    let stories: [StoryDTO]

    var id: String { author.id }
    var hasUnseen: Bool { stories.contains { !$0.viewed } }
}

/// Group flat list theo author, giữ nguyên thứ tự server trả về
/// (story của mình đứng đầu).
func groupStories(_ stories: [StoryDTO]) -> [StoryGroup] {
    var order: [String] = []
    var byAuthor: [String: [StoryDTO]] = [:]
    for story in stories {
        if byAuthor[story.authorId] == nil { order.append(story.authorId) }
        byAuthor[story.authorId, default: []].append(story)
    }
    return order.compactMap { authorId in
        guard let stories = byAuthor[authorId], let first = stories.first else { return nil }
        return StoryGroup(author: first.author.toUserProfile(), stories: stories)
    }
}

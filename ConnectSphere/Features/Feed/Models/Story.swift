import Foundation

// MARK: - Stories
/// A 24h story (backend returns a flat list, client groups by author)
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

// MARK: - Viewers
/// Someone who has viewed one of the current user's stories (GET /stories/:id/viewers)
struct StoryViewerDTO: Decodable, Identifiable {
    let id: String
    let displayName: String
    let avatarColor: String?
    let avatarUrl: String?
    let viewedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case avatarColor = "avatar_color"
        case avatarUrl   = "avatar_url"
        case viewedAt    = "viewed_at"
    }
}

// MARK: - Grouping
/// One person's stories, used for the bubble + viewer
struct StoryGroup: Identifiable {
    let author: UserProfile
    let stories: [StoryDTO]

    var id: String { author.id }
    var hasUnseen: Bool { stories.contains { !$0.viewed } }
}

/// Groups the flat list by author, preserving the order the server returns
/// (the current user's own story comes first).
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

import Foundation

/// One line of your activity log: a comment you wrote, or something you liked.
struct ActivityItem: Identifiable, Decodable, Hashable {
    enum Kind: String, Decodable { case comment, postLike = "post_like", commentLike = "comment_like" }

    let kind: Kind
    let id: String
    let createdAt: Date
    let mode: AppMode
    let postId: String
    let postExcerpt: String
    let postAuthorName: String
    let commentId: String?
    let commentExcerpt: String?

    enum CodingKeys: String, CodingKey {
        case kind, id, mode
        case createdAt = "created_at"
        case postId = "post_id"
        case postExcerpt = "post_excerpt"
        case postAuthorName = "post_author_name"
        case commentId = "comment_id"
        case commentExcerpt = "comment_excerpt"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(Kind.self, forKey: .kind)
        id = try c.decode(String.self, forKey: .id)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        mode = AppMode(rawValue: try c.decode(String.self, forKey: .mode)) ?? .hobby
        postId = try c.decode(String.self, forKey: .postId)
        postExcerpt = try c.decode(String.self, forKey: .postExcerpt)
        postAuthorName = try c.decode(String.self, forKey: .postAuthorName)
        commentId = try c.decodeIfPresent(String.self, forKey: .commentId)
        commentExcerpt = try c.decodeIfPresent(String.self, forKey: .commentExcerpt)
    }

    /// "You commented on An's post", "You liked a comment on An's post"…
    func headline(loc: (String) -> String) -> String {
        switch kind {
        case .comment: String(format: loc("You commented on %@'s post"), postAuthorName)
        case .postLike: String(format: loc("You liked %@'s post"), postAuthorName)
        case .commentLike: String(format: loc("You liked a comment on %@'s post"), postAuthorName)
        }
    }
}

/// Day sections, newest first.
enum ActivityGrouping {
    struct Day: Identifiable {
        let id: Date
        let items: [ActivityItem]
    }

    static func byDay(_ items: [ActivityItem], calendar: Calendar = .current) -> [Day] {
        var order: [Date] = []
        var groups: [Date: [ActivityItem]] = [:]
        for item in items {
            let day = calendar.startOfDay(for: item.createdAt)
            if groups[day] == nil { order.append(day) }
            groups[day, default: []].append(item)
        }
        return order.map { Day(id: $0, items: groups[$0] ?? []) }
    }
}

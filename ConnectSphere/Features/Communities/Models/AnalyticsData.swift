import Foundation

/// Full analytics summary returned by GET /api/communities/:id/analytics
struct CommunityAnalytics: Decodable {
    let totalMembers:     Int
    let totalPosts:       Int
    let memberGrowthRate: Double
    let postGrowthRate:   Double
    let dailySnapshots:   [DailySnapshot]
    let topPosts:         [AnalyticsPost]

    enum CodingKeys: String, CodingKey {
        case totalMembers     = "totalMembers"
        case totalPosts       = "totalPosts"
        case memberGrowthRate = "memberGrowthRate"
        case postGrowthRate   = "postGrowthRate"
        case dailySnapshots   = "dailySnapshots"
        case topPosts         = "topPosts"
    }
}

/// One day's analytics snapshot — used as chart data points
struct DailySnapshot: Decodable {
    let snapshotDate:  String  // "YYYY-MM-DD" — kept as String for x-axis labels
    let memberCount:   Int
    let postCount:     Int
    let newMembers:    Int
    let newPosts:      Int
    let activeMembers: Int

    enum CodingKeys: String, CodingKey {
        case snapshotDate  = "snapshot_date"
        case memberCount   = "member_count"
        case postCount     = "post_count"
        case newMembers    = "new_members"
        case newPosts      = "new_posts"
        case activeMembers = "active_members"
    }

    /// Display-friendly short label ("Jun 5")
    var shortLabel: String {
        let parts = snapshotDate.split(separator: "-")
        guard parts.count == 3,
              let month = Int(parts[1]),
              let day   = Int(parts[2]) else { return snapshotDate }
        let months = ["Jan","Feb","Mar","Apr","May","Jun",
                      "Jul","Aug","Sep","Oct","Nov","Dec"]
        return "\(months[month - 1]) \(day)"
    }
}

/// Minimal post data used in top-posts list within analytics
struct AnalyticsPost: Identifiable, Decodable {
    let id:           String
    let content:      String
    let likeCount:    Int
    let commentCount: Int
    let createdAt:    Date
    let author:       CommunityPostAuthor?

    enum CodingKeys: String, CodingKey {
        case id, content, author
        case likeCount    = "like_count"
        case commentCount = "comment_count"
        case createdAt    = "created_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id           = try c.decode(String.self, forKey: .id)
        content      = try c.decode(String.self, forKey: .content)
        likeCount    = try c.decode(Int.self,    forKey: .likeCount)
        commentCount = try c.decode(Int.self,    forKey: .commentCount)
        createdAt    = try c.decode(Date.self,   forKey: .createdAt)
        author       = try c.decodeIfPresent(CommunityPostAuthor.self, forKey: .author)
    }
}

/// Response wrapper for the moderation queue
struct ModerationQueueResponse: Decodable {
    let reports:      [ModerationItem]
    let pendingCount: Int

    enum CodingKeys: String, CodingKey {
        case reports
        case pendingCount = "pendingCount"
    }
}

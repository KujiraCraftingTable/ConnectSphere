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

/// One day's analytics snapshot. Used as chart data points
struct DailySnapshot: Decodable {
    let snapshotDate:  String  // "YYYY-MM-DD", kept as String for x-axis labels
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

    /// Display-friendly short label ("Jun 5", or "5 thg 6" in Vietnamese),
    /// locale-aware rather than a fixed English month table, so the x-axis
    /// follows the in-app language. Same "read the saved language, fall back
    /// to the device locale" convention as `Bundle.app` and `AppState.init()`.
    var shortLabel: String {
        guard let date = Self.inputFormatter.date(from: snapshotDate) else { return snapshotDate }

        let languageCode = UserDefaults.standard.string(forKey: "appLanguage")
            ?? Locale.current.language.languageCode?.identifier ?? "en"
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: languageCode)
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        return formatter.string(from: date)
    }

    private static let inputFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
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


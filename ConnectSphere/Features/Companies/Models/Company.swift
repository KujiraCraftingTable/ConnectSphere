import Foundation

/// A company's official page (Work mode), as the signed-in user sees it.
struct Company: Identifiable, Decodable, Hashable {
    let id: String
    var name: String
    var slug: String
    var logoUrl: String?
    var coverUrl: String?
    var about: String?
    var industry: String?
    var size: String?
    var website: String?
    var headquarters: String?
    var foundedYear: Int?
    /// Verified by the app admin — shown as "Official".
    var isVerified: Bool
    var followerCount: Int
    var isFollowing: Bool
    /// "owner" / "admin" when the signed-in user runs the page.
    var myRole: String?

    var isAdmin: Bool { myRole != nil }

    /// "IT · 1000+ employees · Hanoi", leaving out what's unknown.
    func summary(employeesLabel: (String) -> String) -> String {
        [industry, size.map(employeesLabel), headquarters].compactMap { $0 }.joined(separator: " · ")
    }

    static let sizes = ["1-10", "11-50", "51-200", "201-500", "501-1000", "1000+"]

    enum CodingKeys: String, CodingKey {
        case id, name, slug, about, industry, size, website, headquarters
        case logoUrl = "logo_url"
        case coverUrl = "cover_url"
        case foundedYear = "founded_year"
        case isVerified = "is_verified"
        case followerCount = "follower_count"
        case isFollowing = "is_following"
        case myRole = "my_role"
    }
}

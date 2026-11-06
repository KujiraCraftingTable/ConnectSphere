import Foundation

/// One suggested hashtag from `GET /tags/suggest?prefix=`. Ranked by usage count.
/// Deliberately not visibility-filtered server-side (a hidden AI tag's text is still
/// a useful suggestion for a user who wants to deliberately type, and thus show, it).
struct TagSuggestionDTO: Decodable {
    let tag: String
    let usageCount: Int

    enum CodingKeys: String, CodingKey {
        case tag
        case usageCount = "usage_count"
    }
}

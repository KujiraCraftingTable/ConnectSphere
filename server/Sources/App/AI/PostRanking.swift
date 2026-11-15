import Foundation

/// Order for AI post search. A post that meets more of what the prompt asks
/// (its topics and its place) always comes before one that meets less; among
/// posts that meet the same number, the most popular comes first. Popularity
/// is likes + shares + comments, counted alike. How close the text is to the
/// topics only breaks ties. The searcher's own taste and what they have
/// already seen play no part: the same prompt gives everyone the same order.
enum PostRanking {
    struct Key: Equatable {
        /// How many of the prompt's criteria the post meets.
        var criteria: Int
        var engagement: Int
        /// Average closeness to the topics it is about.
        var match: Double
    }

    static func engagement(likes: Int, shares: Int, comments: Int) -> Int {
        max(likes, 0) + max(shares, 0) + max(comments, 0)
    }

    /// Whether `a` comes before `b`.
    static func comesFirst(_ a: Key, _ b: Key) -> Bool {
        if a.criteria != b.criteria { return a.criteria > b.criteria }
        if a.engagement != b.engagement { return a.engagement > b.engagement }
        return a.match > b.match
    }
}

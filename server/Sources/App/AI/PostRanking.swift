import Foundation

/// Order for AI post search: how well a post matches the query, nudged up by
/// how much people engaged with it. The nudge is capped small on purpose. It
/// reorders close matches but can't lift a weak match over a clearly better one
/// (hits clear the 0.6 similarity bar and rarely pass 0.85). The match % shown
/// to users stays the pure similarity; only the order uses this.
enum PostRanking {
    static let maxBoost = 0.03
    /// Engagement at which the boost is full: 50 likes, or 25 comments.
    static let fullBoostEngagement = 50.0

    /// Personal nudges (AI_SEARCH_REVIEW.md, phase S5), small for the same
    /// reason: a post close to your taste rises a little, one you've already
    /// seen sinks a little, and your "Not interested" / "Show more like this"
    /// carry over from the feed at a tenth of their strength.
    static let tasteBoost = 0.05, seenWeight = 0.1, feedbackWeight = 0.1

    /// `taste` is 0…1 (`SearchRanking.taste`), `seenPenalty` is
    /// `FeedStore.seenPenalty`, `feedback` is `FeedStore.feedbackAdjustment`.
    static func rankScore(similarity: Double, likes: Int, comments: Int,
                          taste: Double = 0, seenPenalty: Double = 0, feedback: Double = 0) -> Double {
        // A comment takes more effort than a like, so it counts double. Log
        // scale: the first few interactions matter most.
        let engagement = Double(max(likes, 0) + 2 * max(comments, 0))
        let boost = min(1, log1p(engagement) / log1p(fullBoostEngagement))
        return similarity + maxBoost * boost
            + tasteBoost * min(1, max(0, taste)) - seenWeight * seenPenalty + feedbackWeight * feedback
    }
}

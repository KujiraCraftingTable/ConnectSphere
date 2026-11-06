import Foundation

/// The last stage of AI people search (AI_SEARCH_REVIEW.md, phases S2–S5):
/// the fused retrieval list re-ordered by who fits *you*. Your taste, people
/// you share, how active they are, and by what you did after earlier
/// searches, then spread so one city doesn't fill the page.
enum SearchRanking {
    // MARK: Score mix (phase S2)

    /// Retrieval still decides most of it: the prompt is what you asked for.
    static let wRetrieval = 0.65, wTaste = 0.20, wSocial = 0.10, wActivity = 0.05

    /// mxbai cosine between unrelated texts rarely drops under ~0.45 and close
    /// ones seldom pass ~0.85, so that band is stretched to 0…1.
    static let tasteFloor = 0.45, tasteCeil = 0.85

    /// Mutual connections count more than shared communities; each is half
    /// full at its `…Half`.
    static let mutualShare = 0.6, mutualHalf = 2.0, communityHalf = 2.0

    /// Last post, comment or read: full credit today, half after two weeks.
    static let activityHalfLifeDays = 14.0

    // MARK: Learning (phase S3)

    /// Someone you said "Not a fit" to sinks for `dismissDays`; so, a little,
    /// does anyone whose profile is nearly the same as theirs.
    static let dismissDays = 30
    static let dismissedPenalty = 0.5
    static let likeDismissedMin = 0.85, likeDismissedPenalty = 0.2

    /// People you connected with from a search join your taste for this long.
    static let connectedTasteDays = 90, maxConnectedTastes = 5

    struct Features: Decodable {
        var user_id: String
        /// Best cosine between your taste vectors and their profile / posts.
        var taste: Double?
        var shared_communities: Int
        var active_days_ago: Double?
        var dismissed: Bool
        /// Closest profile among people you dismissed lately.
        var dismissed_like: Double?
    }

    static func taste(_ cosine: Double?) -> Double {
        guard let c = cosine else { return 0 }
        return min(1, max(0, (c - tasteFloor) / (tasteCeil - tasteFloor)))
    }

    static func social(mutuals: Int, sharedCommunities: Int) -> Double {
        let m = Double(max(mutuals, 0)), c = Double(max(sharedCommunities, 0))
        return mutualShare * m / (m + mutualHalf) + (1 - mutualShare) * c / (c + communityHalf)
    }

    static func activity(daysAgo: Double?) -> Double {
        guard let d = daysAgo else { return 0 }
        return pow(0.5, max(d, 0) / activityHalfLifeDays)
    }

    static func feedbackPenalty(dismissed: Bool, likeDismissed: Double?) -> Double {
        (dismissed ? dismissedPenalty : 0)
            + ((likeDismissed ?? 0) >= likeDismissedMin ? likeDismissedPenalty : 0)
    }

    /// `retrieval` is 0…1 (the fused score over the best one in the list).
    static func score(retrieval: Double, taste: Double, social: Double, activity: Double) -> Double {
        wRetrieval * retrieval + wTaste * taste + wSocial * social + wActivity * activity
    }

    /// Re-scores and re-orders. People whose name was typed stay on top, in
    /// name order; everyone else by the mix above, minus feedback penalties.
    static func rerank(_ users: [SearchStore.RawUser], features: [String: Features]) -> [SearchStore.RawUser] {
        let best = users.map(\.score).max() ?? 0
        let scored = users.map { u -> SearchStore.RawUser in
            let f = features[u.id]
            var uu = u
            uu.score = score(
                retrieval: best > 0 ? u.score / best : 0,
                taste: taste(f?.taste),
                social: social(mutuals: u.mutual_count, sharedCommunities: f?.shared_communities ?? 0),
                activity: activity(daysAgo: f?.active_days_ago))
                - feedbackPenalty(dismissed: f?.dismissed ?? false, likeDismissed: f?.dismissed_like)
            return uu
        }
        return scored.sorted {
            if ($0.name_match > 0) != ($1.name_match > 0) { return $0.name_match > 0 }
            if $0.name_match != $1.name_match { return $0.name_match > $1.name_match }
            return $0.score > $1.score
        }
    }

    // MARK: Diversity (phase S5)

    /// Within each run of 10, at most 3 people from one city
    /// (`FeedStore.spread`), so one district doesn't fill the page. Name
    /// matches stay first, and a prompt that named a place isn't spread,
    /// everyone is from there on purpose. Topics aren't spread: a prompt about
    /// one thing should return people about that thing.
    static func diversify(_ users: [SearchStore.RawUser], byPlace: Bool) -> [SearchStore.RawUser] {
        guard byPlace else { return users }
        let named = users.filter { $0.name_match > 0 }
        let rest = users.filter { $0.name_match <= 0 }
        return named + FeedStore.spread(rest, author: \.id, topic: { FeedStore.normalizedPlace($0.location) })
    }
}

@testable import App
import XCTest

/// The Phase B ranking math (FEED_RANKING_REVIEW.md).
final class FeedScoringTests: XCTestCase {
    func testActionsHalveEveryTwoWeeks() {
        XCTAssertEqual(FeedStore.decayed(2, ageDays: 0), 2, accuracy: 1e-9)
        XCTAssertEqual(FeedStore.decayed(2, ageDays: 14), 1, accuracy: 1e-9)
        XCTAssertEqual(FeedStore.decayed(2, ageDays: 28), 0.5, accuracy: 1e-9)
        // A skip counts against, and fades the same way.
        XCTAssertEqual(FeedStore.decayed(FeedStore.Action.fastSkip, ageDays: 14), -0.25, accuracy: 1e-9)
    }

    func testSharesSayMoreThanLikes() {
        XCTAssertGreaterThan(FeedStore.Action.share, FeedStore.Action.comment)
        XCTAssertGreaterThan(FeedStore.Action.comment, FeedStore.Action.like)
        XCTAssertLessThan(FeedStore.Action.fastSkip, 0)
    }

    /// A fresh post loved by the few who saw it beats an old one with more
    /// likes spread over many viewers.
    func testEngagementIsARate() {
        let fresh = FeedStore.engagementScore(likes: 8, comments: 2, shares: 0, viewers: 10)
        let old = FeedStore.engagementScore(likes: 30, comments: 0, shares: 0, viewers: 600)
        XCTAssertGreaterThan(fresh, old)
        XCTAssertEqual(FeedStore.engagementScore(likes: 0, comments: 0, shares: 0, viewers: 50), 0)
        XCTAssertLessThan(FeedStore.engagementScore(likes: 10_000, comments: 0, shares: 0, viewers: 0), 1)
    }

    /// Phase C: "Not interested" sinks posts like it and its author; "Show
    /// more like this" lifts them; nothing changes without feedback.
    func testFeedbackMovesSimilarPostsAndAuthor() {
        XCTAssertEqual(FeedStore.feedbackAdjustment(lessSimilar: false, lessAuthor: false,
                                                    moreSimilar: false, moreAuthor: false), 0)
        let less = FeedStore.feedbackAdjustment(lessSimilar: true, lessAuthor: true, moreSimilar: false, moreAuthor: false)
        let more = FeedStore.feedbackAdjustment(lessSimilar: false, lessAuthor: false, moreSimilar: true, moreAuthor: true)
        XCTAssertLessThan(less, -0.5)
        XCTAssertGreaterThan(more, 0.25)
        // A disliked author sinks further than a liked one rises.
        XCTAssertGreaterThan(-less, more)
        XCTAssertLessThan(FeedStore.Action.notInterested, 0)
        XCTAssertTrue(FeedStore.feedbackKinds == ["less", "more"])
    }

    // MARK: Phase D

    /// Two clearly different interests stay two, instead of one average.
    func testTwoInterestsStaySeparate() {
        let jpop: [[Double]] = [[1, 0.1, 0], [0.9, 0, 0.1], [1, 0, 0]]
        let ios: [[Double]] = [[0, 1, 0.1], [0.1, 0.9, 0], [0, 1, 0]]
        let c = FeedStore.clusterTaste(jpop + ios, weights: Array(repeating: 1, count: 6), maxK: 4)
        XCTAssertEqual(c.count, 2)
        // Each interest is close to one group and far from the other.
        let dots = c.map { $0[0] > $0[1] }
        XCTAssertEqual(Set(dots), [true, false])
    }

    func testFewSignalsMakeOneInterest() {
        XCTAssertEqual(FeedStore.clusterTaste([[1, 0], [0, 1]], weights: [1, 1], maxK: 4).count, 1)
        XCTAssertTrue(FeedStore.clusterTaste([], weights: [], maxK: 4).isEmpty)
    }

    func testClosenessGrowsWithInteraction() {
        let stranger = FeedStore.closeness(isConnection: false, isFollowing: false, interactions: 0)
        let quietFriend = FeedStore.closeness(isConnection: true, isFollowing: false, interactions: 0)
        let closeFriend = FeedStore.closeness(isConnection: true, isFollowing: true, interactions: 30)
        let followed = FeedStore.closeness(isConnection: false, isFollowing: true, interactions: 0)
        XCTAssertEqual(stranger, 0)
        XCTAssertGreaterThan(quietFriend, followed)
        XCTAssertGreaterThan(closeFriend, quietFriend)
        XCTAssertLessThanOrEqual(closeFriend, 1)
    }

    private struct Item { let id: Int; let author: String; let topic: String? }

    func testSameAuthorNeverTwiceInARowWhenAvoidable() {
        let items = [Item(id: 1, author: "a", topic: nil), Item(id: 2, author: "a", topic: nil),
                     Item(id: 3, author: "a", topic: nil), Item(id: 4, author: "b", topic: nil),
                     Item(id: 5, author: "c", topic: nil)]
        let out = FeedStore.spread(items, author: \.author, topic: \.topic)
        XCTAssertEqual(out.map(\.id), [1, 4, 2, 5, 3])
        XCTAssertEqual(out.count, items.count)   // nothing dropped
    }

    func testTopicCappedAtThreePerTen() {
        let items = (0..<5).map { Item(id: $0, author: "u\($0)", topic: "kpop") }
            + [Item(id: 9, author: "z", topic: "ios")]
        let out = FeedStore.spread(items, author: \.author, topic: \.topic)
        // The fourth kpop post waits until something else has been shown.
        XCTAssertEqual(out.prefix(4).map(\.topic), ["kpop", "kpop", "kpop", "ios"])
    }

    // MARK: Phase E

    func testPeersLiftMoreTheMoreTheyShareYourTaste() {
        XCTAssertEqual(FeedStore.peerLift(0), 0)
        XCTAssertLessThan(FeedStore.peerLift(1), FeedStore.peerLift(6))
        XCTAssertLessThan(FeedStore.peerLift(1_000), FeedStore.peerBoost)
        XCTAssertEqual(FeedStore.peerLift(FeedStore.peerHalf), FeedStore.peerBoost / 2, accuracy: 1e-9)
    }

    func testPlacesMatchWithOrWithoutCity() {
        XCTAssertEqual(FeedStore.normalizedPlace("Ho Chi Minh City"), "ho chi minh")
        XCTAssertEqual(FeedStore.normalizedPlace("  ho chi minh "), "ho chi minh")
        XCTAssertNil(FeedStore.normalizedPlace("   "))
        XCTAssertNil(FeedStore.normalizedPlace(nil))
    }

    func testProfileLanguagesBecomePostCodes() {
        XCTAssertEqual(FeedStore.languageCodes(["Vietnamese", "English", "Klingon"]), ["en", "vi"])
        XCTAssertEqual(FeedStore.languageCodes([]), [])
    }

    /// Interest picks give equal-weight vectors (no weights passed).
    func testClusteringWithoutWeights() {
        let c = FeedStore.clusterTaste([[1, 0], [0.9, 0.1], [1, 0.05]], weights: [], maxK: 4)
        XCTAssertEqual(c.count, 1)
    }

    func testSeenPostsSink() {
        XCTAssertEqual(FeedStore.seenPenalty(firstSeenHoursAgo: nil), 0)
        XCTAssertEqual(FeedStore.seenPenalty(firstSeenHoursAgo: 5), FeedStore.seenRecentPenalty)
        XCTAssertEqual(FeedStore.seenPenalty(firstSeenHoursAgo: 24 * 10), FeedStore.seenOlderPenalty)
        XCTAssertGreaterThan(FeedStore.seenRecentPenalty, FeedStore.seenOlderPenalty)
    }
}

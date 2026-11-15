@testable import App
import XCTest

/// AI_SEARCH_REVIEW.md: S1 keyword + name legs fused with the vector leg;
/// S2–S5 re-ranking by who fits you, learning, diversity.
final class SearchScoringTests: XCTestCase {
    private func user(_ id: String, score: Double = 0.5, retrieval: Double = 0.5, name: Double = 0,
                      evidence: String = "[]", location: String? = nil, mutuals: Int = 0) -> SearchStore.RawUser {
        SearchStore.RawUser(
            id: id, username: id, display_name: nil, bio: nil, avatar_url: nil, cover_url: nil,
            avatar_color: nil, location: location, job_title: nil, company: nil, default_mode: "hobby",
            gender: nil, age: nil, follower_count: 0, following_count: 0, post_count: 0,
            interests: "[]", skills: "[]", score: score, retrieval: retrieval, name_match: name,
            match_evidence: evidence, mutual_count: mutuals)
    }

    private func features(_ id: String, taste: Double? = nil, communities: Int = 0, activeDaysAgo: Double? = nil,
                          dismissed: Bool = false, dismissedLike: Double? = nil) -> SearchRanking.Features {
        SearchRanking.Features(user_id: id, taste: taste, shared_communities: communities,
                               active_days_ago: activeDaysAgo, dismissed: dismissed, dismissed_like: dismissedLike)
    }

    func testFoundTwiceBeatsFoundOnceFirst() {
        let fused = SearchController.rrf([["a", "b"], ["b", "c"]])
        XCTAssertGreaterThan(fused["b"]!, fused["a"]!)
        XCTAssertGreaterThan(fused["a"]!, fused["c"]!)
        XCTAssertEqual(fused["a"]!, 1 / (SearchController.rrfK + 1), accuracy: 1e-12)
    }

    /// "Lý Thảo": the vector leg returns strangers, the name leg finds her.
    func testNameMatchBeatsVectorOnly() {
        let semantic = [user("stranger1", score: 0.66), user("stranger2", score: 0.55)]
        let nameOnly = [user("lythao", score: 0.1, retrieval: 0, name: 1)]
        XCTAssertEqual(SearchController.fuse(semantic: semantic, keyword: nameOnly).first?.id, "lythao")
    }

    /// Without a name, someone found by meaning and by words beats someone
    /// found by only one of them.
    func testTextAndVectorBeatsVectorOnly() {
        let semantic = [user("a", score: 0.7), user("b", score: 0.6)]
        let keyword = [user("b", retrieval: 0.2)]
        XCTAssertEqual(SearchController.fuse(semantic: semantic, keyword: keyword).first?.id, "b")
    }

    func testKeywordOnlyPeopleJoinTheList() {
        let out = SearchController.fuse(semantic: [user("a")], keyword: [user("ios_dev", retrieval: 0.3)])
        XCTAssertEqual(Set(out.map(\.id)), ["a", "ios_dev"])
    }

    func testEvidenceFromBothLegsIsKept() {
        let v = #"[{"source_type":"user_profile","similarity":0.7}]"#
        let k = #"[{"source_type":"post","topic":"ios","similarity":null}]"#
        let out = SearchController.fuse(semantic: [user("a", evidence: v)],
                                        keyword: [user("a", retrieval: 0.2, evidence: k)])
        let ev = SearchController.decodeEvidence(out[0].match_evidence)
        XCTAssertEqual(Set(ev.map(\.source_type)), ["user_profile", "post"])
    }

    func testNothingFoundStaysEmpty() {
        XCTAssertTrue(SearchController.fuse(semantic: [], keyword: []).isEmpty)
    }

    // MARK: S2, who fits you

    func testTasteStretchesTheUsefulCosineBand() {
        XCTAssertEqual(SearchRanking.taste(nil), 0)
        XCTAssertEqual(SearchRanking.taste(0.3), 0)
        XCTAssertEqual(SearchRanking.taste(0.65), 0.5, accuracy: 1e-9)
        XCTAssertEqual(SearchRanking.taste(0.95), 1)
    }

    func testSocialAndActivityAreBounded() {
        XCTAssertEqual(SearchRanking.social(mutuals: 0, sharedCommunities: 0), 0)
        XCTAssertLessThan(SearchRanking.social(mutuals: 1000, sharedCommunities: 1000), 1)
        XCTAssertGreaterThan(SearchRanking.social(mutuals: 2, sharedCommunities: 0),
                             SearchRanking.social(mutuals: 0, sharedCommunities: 2))
        XCTAssertEqual(SearchRanking.activity(daysAgo: 0), 1)
        XCTAssertEqual(SearchRanking.activity(daysAgo: 14), 0.5, accuracy: 1e-9)
        XCTAssertEqual(SearchRanking.activity(daysAgo: nil), 0)
    }

    func testWeightsSumToOne() {
        XCTAssertEqual(SearchRanking.wRetrieval + SearchRanking.wTaste + SearchRanking.wSocial
                       + SearchRanking.wActivity, 1, accuracy: 1e-9)
    }

    /// Two equally good matches: the one who shares your taste comes first.
    func testTasteBreaksATie() {
        let out = SearchRanking.rerank([user("a", score: 0.03), user("b", score: 0.03)],
                                       features: ["a": features("a", taste: 0.5), "b": features("b", taste: 0.8)])
        XCTAssertEqual(out.first?.id, "b")
    }

    /// Taste nudges; a clearly better match still wins.
    func testTasteNeverBeatsAClearlyBetterMatch() {
        let out = SearchRanking.rerank([user("strong", score: 0.03), user("weak", score: 0.012)],
                                       features: ["weak": features("weak", taste: 0.9, communities: 3, activeDaysAgo: 0)])
        XCTAssertEqual(out.first?.id, "strong")
    }

    func testNameMatchStaysFirst() {
        let out = SearchRanking.rerank([user("tasteful", score: 0.05), user("lythao", score: 0.01, name: 0.8)],
                                       features: ["tasteful": features("tasteful", taste: 0.9)])
        XCTAssertEqual(out.first?.id, "lythao")
    }

    func testLikeMePhrasesAreRecognised() {
        for q in ["a study buddy into the same stuff as me", "someone like me", "tìm bạn giống mình",
                  "người hợp gu với tôi"] {
            XCTAssertTrue(OllamaService.mentionsLikeMe(q), q)
        }
        for q in ["find iOS developers", "tìm người như anh Sơn Tùng", "someone who likes meat"] {
            XCTAssertFalse(OllamaService.mentionsLikeMe(q), q)
        }
    }

    func testPersonalLegJoinsTheFusion() {
        let out = SearchController.fuse(semantic: [user("a")], keyword: [], personal: [user("a"), user("me_like")])
        XCTAssertEqual(out.first?.id, "a")
        XCTAssertEqual(Set(out.map(\.id)), ["a", "me_like"])
    }

    // MARK: S3, learning from what you did

    func testDismissedPeopleSink() {
        let out = SearchRanking.rerank([user("a", score: 0.03), user("b", score: 0.025)],
                                       features: ["a": features("a", dismissed: true)])
        XCTAssertEqual(out.map(\.id), ["b", "a"])
        XCTAssertEqual(SearchRanking.feedbackPenalty(dismissed: false, likeDismissed: 0.5), 0)
        XCTAssertEqual(SearchRanking.feedbackPenalty(dismissed: false, likeDismissed: 0.9),
                       SearchRanking.likeDismissedPenalty)
    }

    func testOnlyKnownEventKinds() {
        XCTAssertEqual(Set(SearchStore.eventColumns.keys), ["tap", "dismiss"])
    }

    // MARK: S5, diversity and personal post search

    func testOneCityDoesNotFillThePage() {
        let users = (0..<6).map { user("h\($0)", location: "Hanoi") } + [user("s", location: "Ho Chi Minh City")]
        let out = SearchRanking.diversify(users, byPlace: true)
        XCTAssertEqual(out.count, users.count)
        XCTAssertLessThan(out.firstIndex { $0.id == "s" }!, 6)
        XCTAssertEqual(SearchRanking.diversify(users, byPlace: false).map(\.id), users.map(\.id))
    }
}

import XCTest
@testable import App

final class SuggestionTests: XCTestCase {
    private func reason(_ mode: String = "hobby", mutual: Int = 0, shared: [String] = [],
                        company: String? = nil, province: String? = nil) -> SuggestionStore.Reason {
        SuggestionStore.reason(mode: mode, mutual: mutual, shared: shared, sameCompany: company, sameProvince: province)
    }

    func testReasonPicksTheStrongestTrueThing() {
        let mutual = reason(mutual: 3, shared: ["jpop"], province: "Hà Nội")
        XCTAssertEqual(mutual.kind, "mutual"); XCTAssertEqual(mutual.count, 3)

        let interest = reason(shared: ["jpop", "badminton"], province: "Hà Nội")
        XCTAssertEqual(interest.kind, "interest"); XCTAssertEqual(interest.value, "jpop")

        let skill = reason("work", shared: ["Swift"], company: "Grab")
        XCTAssertEqual(skill.kind, "skill"); XCTAssertEqual(skill.value, "Swift")

        let company = reason("work", company: "Grab", province: "Hà Nội")
        XCTAssertEqual(company.kind, "company"); XCTAssertEqual(company.value, "Grab")

        // Company only counts in Work mode.
        XCTAssertEqual(reason("hobby", company: "Grab", province: "Huế").kind, "place")
        XCTAssertEqual(reason().kind, "similar")
    }

    func testScoreWeighsMutualFriendsMost() {
        let friendOfFriend = SuggestionStore.score(mutual: 2, similarity: 0.3, shared: 0, samePlace: false)
        let lookalike = SuggestionStore.score(mutual: 0, similarity: 0.6, shared: 0, samePlace: false)
        XCTAssertGreaterThan(friendOfFriend, lookalike)
        // Capped: 50 mutual friends don't drown everything else out.
        XCTAssertEqual(SuggestionStore.score(mutual: 50, similarity: nil, shared: 0, samePlace: false), 0.4, accuracy: 1e-9)
        XCTAssertEqual(SuggestionStore.score(mutual: 5, similarity: 1, shared: 9, samePlace: true), 1.0, accuracy: 1e-9)
        // No embedding (nil) or a negative cosine never lowers the score.
        XCTAssertEqual(SuggestionStore.score(mutual: 0, similarity: -0.4, shared: 0, samePlace: false), 0, accuracy: 1e-9)
    }

    func testOnlyKnownModes() throws {
        XCTAssertEqual(try PeopleController.validMode("hobby"), "hobby")
        XCTAssertThrowsError(try PeopleController.validMode("friend"))
        XCTAssertThrowsError(try PeopleController.validMode(nil))
    }
}

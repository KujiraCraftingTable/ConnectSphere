@testable import App
import XCTest

/// Distance search: only the app's radius steps are accepted, and a result
/// without a radius carries no distance.
final class WardRadiusTests: XCTestCase {
    func testOnlyTheFiveKilometreStepsAreAccepted() {
        for km in [5.0, 10, 15, 20, 25, 30] { XCTAssertTrue(SearchStore.radiusStepsKm.contains(km), "\(km)") }
        for km in [0.0, 1, 4, 7, 12.5, 35, 100] { XCTAssertFalse(SearchStore.radiusStepsKm.contains(km), "\(km)") }
    }

    func testAResultHasNoDistanceUnlessTheQuerySetOne() {
        let u = SearchStore.RawUser(
            id: "u", username: "u", display_name: nil, bio: nil, avatar_url: nil, cover_url: nil,
            avatar_color: nil, location: "Ho Chi Minh", job_title: nil, company: nil, default_mode: "hobby",
            gender: nil, age: nil, follower_count: 0, following_count: 0, post_count: 0,
            interests: "[]", skills: "[]", score: 1, retrieval: 1, name_match: 0, match_evidence: "[]", mutual_count: 0)
        XCTAssertNil(u.distance_km)
    }
}

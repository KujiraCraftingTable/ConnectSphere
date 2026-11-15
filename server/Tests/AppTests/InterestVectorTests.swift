@testable import App
import XCTest

/// Interests are clusters of the posts someone wrote or reacted to (migration 144).
final class InterestVectorTests: XCTestCase {
    private let football: [Double] = [1, 0, 0], cooking: [Double] = [0, 1, 0]

    func testTwoTopicsStaySeparateInterests() {
        let vectors = [football, football, football, cooking, cooking, cooking]
        let built = InterestVectorService.clusters(vectors, weights: [1, 1, 1, 0.8, 0.8, 0.8])
        XCTAssertEqual(built.count, 2)
        // Heaviest first: the three authored posts outweigh the three likes.
        XCTAssertEqual(built[0].centroid, football)
        XCTAssertEqual(built[0].weight, 3, accuracy: 1e-9)
        XCTAssertEqual(built[1].centroid, cooking)
        XCTAssertEqual(built[1].weight, 2.4, accuracy: 1e-9)
        XCTAssertEqual(built.map(\.postCount), [3, 3])
    }

    func testAFewPostsMakeOneInterest() {
        let built = InterestVectorService.clusters([football, cooking], weights: [1, 0.8])
        XCTAssertEqual(built.count, 1)
        XCTAssertEqual(built[0].postCount, 2)
        XCTAssertEqual(built[0].weight, 1.8, accuracy: 1e-9)
    }

    func testNeverMoreThanFiveInterests() {
        let vectors = (0..<40).map { i in (0..<8).map { $0 == i % 8 ? 1.0 : 0.0 } }
        let built = InterestVectorService.clusters(vectors, weights: [])
        XCTAssertLessThanOrEqual(built.count, InterestVectorService.maxClusters)
        XCTAssertEqual(built.reduce(0) { $0 + $1.postCount }, 40)
    }

    func testNoPostsNoInterests() {
        XCTAssertTrue(InterestVectorService.clusters([], weights: []).isEmpty)
    }
}

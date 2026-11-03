@testable import App
import XCTest

final class ImpressionFoldTests: XCTestCase {
    private let a = "11111111-1111-1111-1111-111111111111"
    private let b = "22222222-2222-2222-2222-222222222222"

    private func item(_ id: String, _ ms: Int?, opened: Bool? = nil) -> ImpressionStore.Item {
        ImpressionStore.Item(post_id: id, view_ms: ms, opened: opened)
    }

    func testSightingsOfOnePostAddUp() {
        let t = ImpressionStore.fold([item(a, 3_000), item(a, 400), item(b, 5_000)])
        XCTAssertEqual(t.count, 2)
        XCTAssertEqual(t[0], .init(postID: a, views: 2, viewMs: 3_400, fastSkips: 1, opened: false))
        XCTAssertEqual(t[1], .init(postID: b, views: 1, viewMs: 5_000, fastSkips: 0, opened: false))
    }

    func testOpenWithoutTimeIsNotAView() {
        let t = ImpressionStore.fold([item(a, 0, opened: true)])
        XCTAssertEqual(t, [.init(postID: a, views: 0, viewMs: 0, fastSkips: 0, opened: true)])
    }

    func testBadIdsAreDroppedAndTimesCapped() {
        let t = ImpressionStore.fold([item("not-a-uuid", 2_000), item(a, 99_999_999), item(b, -5)])
        XCTAssertEqual(t.map(\.postID), [a, b])
        XCTAssertEqual(t[0].viewMs, ImpressionStore.maxViewMs)
        XCTAssertEqual(t[1].views, 0)
    }
}

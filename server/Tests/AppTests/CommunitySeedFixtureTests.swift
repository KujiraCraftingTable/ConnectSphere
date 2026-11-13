@testable import App
import XCTest

/// `Seeds/demo-communities.json` keeps the shape `seed-demo communities`
/// promises: 6 communities of 5–10 members, at most 2 posts per member,
/// 2–3 listings each, and items the schema's CHECKs accept.
final class CommunitySeedFixtureTests: XCTestCase {
    private func fixture() throws -> SeedDemoCommand.CommunityFixture {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Seeds/demo-communities.json")
        return try JSONDecoder().decode(SeedDemoCommand.CommunityFixture.self, from: Data(contentsOf: url))
    }

    func testFixtureIsValid() throws {
        XCTAssertNil(SeedDemoCommand.communityFixtureProblem(try fixture()))
    }

    func testEveryCommunityHasAPollAndAnEvent() throws {
        for c in try fixture().communities {
            XCTAssertTrue(c.posts.contains { $0.poll != nil }, c.name)
            XCTAssertTrue(c.posts.contains { $0.event != nil }, c.name)
        }
    }

    func testCatchesAMemberWithTooManyPosts() throws {
        var f = try fixture()
        let first = f.communities[0].posts[0]
        f.communities[0].posts += [first, first]
        XCTAssertNotNil(SeedDemoCommand.communityFixtureProblem(f))
    }
}

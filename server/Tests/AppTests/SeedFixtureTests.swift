@testable import App
import XCTest

/// The demo seed (`Seeds/demo-*.json`): every text unique, every commenter a
/// seed person, and hashtags split off the way the composer stores them.
final class SeedFixtureTests: XCTestCase {
    private func load(_ name: String) throws -> SeedDemoCommand.Fixture {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try JSONDecoder().decode(SeedDemoCommand.Fixture.self,
                                        from: Data(contentsOf: dir.appendingPathComponent("Seeds/\(name)")))
    }

    func testTheFixturesAreUsable() throws {
        let hobby = try load("demo-hobby.json"), work = try load("demo-work.json")
        XCTAssertNil(SeedDemoCommand.fixtureProblem(hobby: hobby, work: work))
        XCTAssertEqual(hobby.people.count, 20)
        XCTAssertEqual(work.people.count, 20)
        // Four groups of five in each mode.
        for people in [hobby.people, work.people] {
            XCTAssertEqual(Dictionary(grouping: people, by: \.grp).mapValues(\.count).values.sorted(), [5, 5, 5, 5])
        }
        // The contract scripts look this user up by name.
        XCTAssertTrue(work.people.contains { $0.u == "duonghung" })
    }

    func testHashtagsLeaveTheContent() {
        let split = SeedDemoCommand.splitHashtags("Leo rank tối nay #valorant #Esports #valorant")
        XCTAssertEqual(split.content, "Leo rank tối nay")
        XCTAssertEqual(split.tags, ["valorant", "esports"])
    }
}

@testable import App
import NIOEmbedded
import PostgresKit
import XCTest

/// Typed (non-AI) People search matches name words and @username only.
/// No database in unit tests, so these check the SQL the store builds.
final class PeopleKeywordSearchTests: XCTestCase {
    /// Only renders SQL; `execute` is never reached.
    private struct RenderOnlyDB: SQLDatabase {
        let logger = Logger(label: "render-only")
        let eventLoop: any EventLoop = EmbeddedEventLoop()
        var dialect: any SQLDialect { PostgresDialect() }
        func execute(sql query: any SQLExpression, _ onRow: @escaping @Sendable (any SQLRow) -> ()) -> EventLoopFuture<Void> {
            eventLoop.makeSucceededVoidFuture()
        }
    }

    private func render(_ q: SQLQueryString) -> (sql: String, binds: [String]) {
        var s = SQLSerializer(database: RenderOnlyDB())
        q.serialize(to: &s)
        return (s.sql, s.binds.map { "\($0)" })
    }

    /// "thanh" found Vũ Phương Lan through "hoàn thành" in her bio.
    func testABioWordDoesNotMakeSomeoneMatch() {
        let match = render(UserStore.peopleMatch(words: ["thanh"], alias: "r")).sql
        for field in ["bio", "job_title", "company", "location", "interests", "skills"] {
            XCTAssertFalse(match.contains(field), "\(field) must not decide a typed match")
        }
        XCTAssertTrue(match.contains("r.display_name"))
        XCTAssertTrue(match.contains("r.username"))
    }

    func testEveryWordMustMatchNameOrUsername() {
        let (sql, binds) = render(UserStore.peopleMatch(words: ["thanh", "phong"], alias: "r"))
        XCTAssertEqual(binds, ["thanh", "thanh", "phong", "phong"])
        XCTAssertEqual(sql.components(separatedBy: ") AND (").count, 2, "words are ANDed")
    }

    /// "thanh" finds Thanh and Thành; "thành" is more specific and skips Thanh.
    func testAccentsCountOnlyWhenTyped() {
        XCTAssertTrue(UserStore.isPlain("thanh"))
        XCTAssertFalse(UserStore.isPlain("thành"))
        XCTAssertFalse(UserStore.isPlain("đức"))

        let plain = render(UserStore.peopleMatch(words: ["thanh"], alias: "r")).sql
        XCTAssertTrue(plain.contains("unaccent("))

        let decomposed = "tha\u{0300}nh"  // "thành" with a combining grave
        let (accented, binds) = render(UserStore.peopleMatch(words: [decomposed], alias: "r"))
        XCTAssertFalse(accented.contains("unaccent("), "an accented word must not be folded")
        XCTAssertTrue(accented.contains("NFC"))
        XCTAssertEqual(binds.first, "thành", "the typed word is compared in NFC")
    }

    func testNoWordsMatchesNobody() {
        XCTAssertEqual(render(UserStore.peopleMatch(words: [], alias: "r")).sql, "FALSE")
    }

    func testRankingIgnoresProfileText() {
        let sql = render(UserStore.peopleRelevance(query: "thanh", words: ["thanh"])).sql
        XCTAssertFalse(sql.contains("bio"))
        XCTAssertFalse(sql.contains("location"))
    }
}

import Foundation
import Testing
@testable import ConnectSphere

/// The activity log: reading items, their headline, grouping by day.
struct ActivityLogTests {
    private func item(_ kind: String, at date: String, mode: String = "hobby", comment: String? = nil) throws -> ActivityItem {
        let c = comment.map { "\"\($0)\"" } ?? "null"
        let json = """
        {"kind":"\(kind)","id":"\(UUID().uuidString)","created_at":"\(date)","mode":"\(mode)","post_id":"p",
         "post_excerpt":"A post","post_author_name":"Bao","comment_id":null,"comment_excerpt":\(c)}
        """
        return try JSONDecoder.makeISO8601().decode(ActivityItem.self, from: Data(json.utf8))
    }

    @Test func headlines() throws {
        let loc: (String) -> String = { $0 }
        #expect(try item("comment", at: "2026-10-15T09:00:00.000Z", comment: "hi").headline(loc: loc) == "You commented on Bao's post")
        #expect(try item("post_like", at: "2026-10-15T09:00:00.000Z").headline(loc: loc) == "You liked Bao's post")
        #expect(try item("comment_like", at: "2026-10-15T09:00:00.000Z", mode: "work").headline(loc: loc)
                == "You liked a comment on Bao's post")
        #expect(try item("post_like", at: "2026-10-15T09:00:00.000Z", mode: "work").mode == .work)
    }

    @Test func groupsByDayNewestFirst() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let items = [try item("comment", at: "2026-10-15T09:00:00.000Z"),
                     try item("post_like", at: "2026-10-15T01:00:00.000Z"),
                     try item("comment", at: "2026-10-13T20:00:00.000Z")]
        let days = ActivityGrouping.byDay(items, calendar: cal)
        #expect(days.map(\.items.count) == [2, 1])
    }
}

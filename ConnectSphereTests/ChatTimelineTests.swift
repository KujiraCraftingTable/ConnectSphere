import Foundation
import Testing
@testable import ConnectSphere

/// Fixed UTC calendar + fixed "now" so day boundaries and labels don't depend
/// on the machine's time zone or the date the suite runs.
private let utc: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
}()

private func at(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
    utc.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
}

private struct Entry: ChatTimelineEntry {
    let senderId: String
    let createdAt: Date
}

/// Monday 5 October 2026, 16:00 UTC.
private let now = at(2026, 10, 5, 16, 0)

struct ChatTimelineTests {
    // MARK: - Runs

    @Test func onlyTheLastOfAFiveMessageRunEndsIt() {
        let run = (0..<5).map { Entry(senderId: "kujira", createdAt: at(2026, 10, 5, 15, 49 + $0 / 4)) }
        let ends = run.indices.map { ChatTimeline.endsRun(at: $0, in: run, calendar: utc) }
        #expect(ends == [false, false, false, false, true])
    }

    @Test func alternatingSendersEachEndTheirOwnRun() {
        let entries = (0..<4).map { Entry(senderId: $0.isMultiple(of: 2) ? "me" : "them",
                                          createdAt: at(2026, 10, 5, 15, 40 + $0)) }
        #expect(entries.indices.allSatisfy { ChatTimeline.endsRun(at: $0, in: entries, calendar: utc) })
    }

    @Test func separatorEndsARunEvenForTheSameSender() {
        let entries = [Entry(senderId: "me", createdAt: at(2026, 10, 5, 14, 43)),
                       Entry(senderId: "me", createdAt: at(2026, 10, 5, 15, 38))]
        #expect(ChatTimeline.endsRun(at: 0, in: entries, calendar: utc))
    }

    @Test func outOfRangeIndexIsNeitherRunEndNorSeparator() {
        let entries = [Entry(senderId: "me", createdAt: now)]
        #expect(!ChatTimeline.endsRun(at: 3, in: entries, calendar: utc))
        #expect(!ChatTimeline.showsSeparator(before: -1, in: entries, calendar: utc))
    }

    // MARK: - Separators

    @Test func firstMessageAlwaysGetsASeparator() {
        let entries = [Entry(senderId: "me", createdAt: now)]
        #expect(ChatTimeline.showsSeparator(before: 0, in: entries, calendar: utc))
    }

    @Test func twentyNineMinutesIsNotEnoughThirtyIs() {
        let short = [Entry(senderId: "a", createdAt: at(2026, 10, 5, 10, 0)),
                     Entry(senderId: "b", createdAt: at(2026, 10, 5, 10, 29))]
        let long = [Entry(senderId: "a", createdAt: at(2026, 10, 5, 10, 0)),
                    Entry(senderId: "b", createdAt: at(2026, 10, 5, 10, 30))]
        #expect(!ChatTimeline.showsSeparator(before: 1, in: short, calendar: utc))
        #expect(ChatTimeline.showsSeparator(before: 1, in: long, calendar: utc))
    }

    @Test func crossingMidnightForcesASeparatorUnderThirtyMinutes() {
        let entries = [Entry(senderId: "a", createdAt: at(2026, 10, 4, 23, 50)),
                       Entry(senderId: "a", createdAt: at(2026, 10, 5, 0, 5))]
        #expect(ChatTimeline.showsSeparator(before: 1, in: entries, calendar: utc))
        #expect(ChatTimeline.endsRun(at: 0, in: entries, calendar: utc))
    }

    // MARK: - Labels

    private func label(_ date: Date, dayLocale: String = "en_US", yesterday: String = "Yesterday") -> String {
        ChatTimeline.separatorLabel(for: date, now: now, calendar: utc,
                                    dayLocale: Locale(identifier: dayLocale),
                                    timeLocale: Locale(identifier: "en_GB"),
                                    yesterday: yesterday)
    }

    @Test func todayIsJustTheTime() {
        #expect(label(at(2026, 10, 5, 15, 49)) == "15:49")
    }

    @Test func yesterdayUsesTheLocalizedWord() {
        #expect(label(at(2026, 10, 4, 15, 49)) == "Yesterday 15:49")
        #expect(label(at(2026, 10, 4, 15, 49), dayLocale: "vi_VN", yesterday: "Hôm qua") == "Hôm qua 15:49")
    }

    @Test func withinTheWeekUsesTheWeekday() {
        // Friday 2 October 2026.
        #expect(label(at(2026, 10, 2, 15, 49)) == "Fri 15:49")
    }

    @Test func earlierThisYearUsesMonthAndDay() {
        #expect(label(at(2026, 9, 12, 15, 49)) == "Sep 12 15:49")
    }

    @Test func aPastYearIncludesTheYear() {
        #expect(label(at(2025, 9, 12, 15, 49)) == "Sep 12, 2025 15:49")
    }

    @Test func vietnameseOrdersDayBeforeMonth() {
        #expect(label(at(2026, 9, 12, 15, 49), dayLocale: "vi_VN").hasPrefix("12"))
    }
}

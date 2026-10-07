import Foundation
import Testing
@testable import ConnectSphere

struct NotificationSectionTests {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Ho_Chi_Minh")!
        return c
    }
    /// Wed 7 Oct 2026, 14:00 local.
    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: 7, hour: 14))!
    }
    private func daysAgo(_ d: Int, hour: Int = 9) -> Date {
        let day = calendar.date(byAdding: .day, value: -d, to: now)!
        return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day)!
    }
    private func bucket(_ date: Date) -> NotificationDateBucket {
        NotificationDateBucket.bucket(for: date, now: now, calendar: calendar)
    }

    @Test func todayAndYesterday() {
        #expect(bucket(daysAgo(0, hour: 0)) == .today)
        #expect(bucket(daysAgo(1, hour: 23)) == .yesterday)
        #expect(bucket(daysAgo(1, hour: 0)) == .yesterday)
    }

    @Test func thisWeekThenEarlier() {
        #expect(bucket(daysAgo(2)) == .thisWeek)
        #expect(bucket(daysAgo(7, hour: 0)) == .thisWeek)   // start of the 7th day back is still in
        #expect(bucket(daysAgo(8)) == .earlier)
        #expect(bucket(daysAgo(40)) == .earlier)
    }

    @Test func bucketsAreOrderedNewestFirst() {
        #expect(NotificationDateBucket.allCases == [.today, .yesterday, .thisWeek, .earlier])
    }
}

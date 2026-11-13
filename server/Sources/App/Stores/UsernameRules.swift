import Foundation

/// The @username format and how often it may change (migration 141). Pure, so
/// it's testable; `UserStore.changeUsername` applies the cooldown.
enum UsernameRules {
    static let regex = try! NSRegularExpression(pattern: "^[a-z0-9_]{3,30}$")
    static let formatReason = "Username must be 3-30 characters: lowercase letters, numbers, underscore"
    static let takenReason = "Username already taken"
    static let sameReason = "That's already your username"

    static let cooldownMonths = 6

    /// Trimmed, lowercased, without a leading `@` (people type it).
    static func normalized(_ raw: String?) -> String {
        var s = (raw ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        if s.hasPrefix("@") { s.removeFirst() }
        return s
    }

    static func isValidFormat(_ username: String) -> Bool {
        regex.firstMatch(in: username, range: NSRange(username.startIndex..., in: username)) != nil
    }

    /// When the next change is allowed, or nil if the name has never changed.
    /// Calendar months, so a change on 31 August opens again at the end of February.
    static func nextChange(after lastChangedAt: Date?) -> Date? {
        guard let lastChangedAt else { return nil }
        return calendar.date(byAdding: .month, value: cooldownMonths, to: lastChangedAt)
    }

    static func canChange(lastChangedAt: Date?, now: Date = Date()) -> Bool {
        guard let next = nextChange(after: lastChangedAt) else { return true }
        return now >= next
    }

    /// The app shows its own localized line from `username_next_change_at`;
    /// this is for any other client.
    static func cooldownReason(until date: Date) -> String {
        "You can change your username again on \(dayFormatter.string(from: date))."
    }

    private static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "d MMMM yyyy"
        return f
    }()
}

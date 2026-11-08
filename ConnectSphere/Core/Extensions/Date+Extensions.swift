import Foundation

extension Date {
    /// A "time ago" string localized through .strings (English key + Vietnamese translation).
    var timeAgoString: String {
        let b = Bundle.app
        let seconds = Int(-timeIntervalSinceNow)
        let days = seconds / 86400

        if seconds < 60    { return b.loc("Just now") }
        if seconds < 3600  { return String(format: b.loc("%dm ago"), seconds / 60) }
        if seconds < 86400 { return String(format: b.loc("%dh ago"), seconds / 3600) }
        if days < 8        { return String(format: b.loc("%dd ago"), days) }
        if days < 15       { return b.loc("1w ago") }

        // Absolute date: day first (dd/MM/yyyy) in both languages, the Vietnamese
        // convention the app's users read.
        return dayMonthYear
    }

    /// "08/11/2026". Numeric dates are always day first, whatever the language;
    /// the system's English style would put the month first.
    var dayMonthYear: String { Self.dayMonthYearFormatter.string(from: self) }

    /// "08/11, 3:05 PM": day first, with the time in the device's own style.
    var dayMonthTime: String {
        Self.dayMonthFormatter.string(from: self) + ", " + formatted(date: .omitted, time: .shortened)
    }

    private static let dayMonthYearFormatter = fixedFormatter("dd/MM/yyyy")
    private static let dayMonthFormatter = fixedFormatter("dd/MM")

    private static func fixedFormatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = format
        return f
    }
}

extension Date {
    /// ConnectSphere is 16+: the latest birthday a person may pick. Mirrors
    /// `BirthdayRules.minimumAge` on the server, which is what enforces it.
    static var latestBirthdayFor16Plus: Date {
        Calendar.current.date(byAdding: .year, value: -16, to: Date()) ?? Date()
    }
}

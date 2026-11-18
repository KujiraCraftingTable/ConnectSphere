import Foundation

/// What the chat timeline rules read. `Message` conforms; tests use a small
/// stand-in, since `Message` itself can only be built by decoding.
protocol ChatTimelineEntry {
    var createdAt: Date { get }
}

extension Message: ChatTimelineEntry {}

/// Messenger-style chat timeline rules: when a centered time separator goes
/// between two messages (bubbles carry no time of their own). Kept free of SwiftUI so the rules are unit-tested
/// directly (`ChatTimelineTests`) rather than only by eye in the simulator.
enum ChatTimeline {
    /// Silence long enough to earn a centered time label.
    static let separatorGap: TimeInterval = 20 * 60

    /// Whether a centered time label goes above `entries[i]`: the first
    /// message, 20+ minutes since the one before it, or a calendar-day
    /// change. The day change applies even under 20 minutes, otherwise a
    /// 23:50 → 00:05 exchange sits under one label naming the wrong day.
    static func showsSeparator<E: ChatTimelineEntry>(before i: Int, in entries: [E],
                                                     calendar: Calendar = .current) -> Bool {
        guard entries.indices.contains(i) else { return false }
        guard i > 0 else { return true }
        let previous = entries[i - 1].createdAt
        let current = entries[i].createdAt
        return current.timeIntervalSince(previous) >= separatorGap
            || !calendar.isDate(previous, inSameDayAs: current)
    }

    /// The separator's text: "15:49" today, "Yesterday 15:49", "Mon 15:49"
    /// within the week, "Sep 12 15:49" earlier this year, "Sep 12, 2025 15:49"
    /// before that (English; Vietnamese orders day before month).
    ///
    /// Two locales on purpose. Day and month words follow the app's own
    /// language setting (`dayLocale`), like `Date.timeAgoString`. The device
    /// may be English while the app is set to Vietnamese. The time follows
    /// `timeLocale`, the device's, so it carries the user's 12/24-hour choice
    /// a locale built from an identifier would
    /// drop that override.
    static func separatorLabel(for date: Date, now: Date = .now, calendar: Calendar = .current,
                               dayLocale: Locale = appLanguageLocale,
                               timeLocale: Locale = .autoupdatingCurrent,
                               yesterday: String) -> String {
        let time = date.formatted(Date.FormatStyle(locale: timeLocale, calendar: calendar,
                                                   timeZone: calendar.timeZone).hour().minute())
        let dayDelta = calendar.dateComponents([.day], from: calendar.startOfDay(for: date),
                                               to: calendar.startOfDay(for: now)).day ?? 0
        let day: String?
        switch dayDelta {
        case ...0: day = nil
        case 1:    day = yesterday
        case 2..<7: day = formatter(template: "EEE", locale: dayLocale, calendar: calendar).string(from: date)
        default:
            let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
            day = formatter(template: sameYear ? "dMMM" : "dMMMy", locale: dayLocale, calendar: calendar)
                .string(from: date)
        }
        return day.map { "\($0) \(time)" } ?? time
    }

    /// The app's chosen language as a locale. Same source and fallback as
    /// `Date.timeAgoString` (`appLanguage`, else the device language).
    static var appLanguageLocale: Locale {
        let language = AppDefaults.store.string(forKey: "appLanguage")
            ?? Locale.current.language.languageCode?.identifier ?? "en"
        return Locale(identifier: language == "vi" ? "vi_VN" : "en_US")
    }

    /// Cached because the label is recomputed for every separator on every
    /// list render, and building a `DateFormatter` is comparatively expensive.
    private static var formatterCache: [String: DateFormatter] = [:]

    private static func formatter(template: String, locale: Locale, calendar: Calendar) -> DateFormatter {
        let key = "\(template)|\(locale.identifier)|\(calendar.timeZone.identifier)"
        if let cached = formatterCache[key] { return cached }
        let f = DateFormatter()
        f.locale = locale
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.setLocalizedDateFormatFromTemplate(template)
        formatterCache[key] = f
        return f
    }
}

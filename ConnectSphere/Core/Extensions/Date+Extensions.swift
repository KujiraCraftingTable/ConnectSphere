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

        // Absolute date: formatted according to the currently selected language.
        // Falls back to the device locale (not a hardcoded "vi") before the
        // setting is first persisted — same convention as AppState.init() and
        // Bundle.app, which both derive from Locale.current rather than
        // assuming Vietnamese.
        let savedLanguage = UserDefaults.standard.string(forKey: "appLanguage")
            ?? Locale.current.language.languageCode?.identifier ?? "en"
        let isVi = savedLanguage == "vi"
        return Self.shortDateFormatter(
            locale: isVi ? "vi_VN" : "en_US",
            format: isVi ? "dd/MM/yyyy" : "MM/dd/yyyy"
        ).string(from: self)
    }

    private static var dateFormatterCache: [String: DateFormatter] = [:]

    private static func shortDateFormatter(locale: String, format: String) -> DateFormatter {
        if let cached = dateFormatterCache[locale] { return cached }
        let f = DateFormatter()
        f.locale = Locale(identifier: locale)
        f.dateFormat = format
        dateFormatterCache[locale] = f
        return f
    }
}

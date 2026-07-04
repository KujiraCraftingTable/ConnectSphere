import Foundation

extension Date {
    var timeAgoString: String {
        let lang = AppLanguage(rawValue: UserDefaults.standard.string(forKey: "appLanguage") ?? "vi") ?? .vietnamese
        let seconds = Int(-timeIntervalSinceNow)
        let days = seconds / 86400

        switch lang {
        case .vietnamese:
            if seconds < 60    { return "Vừa xong" }
            if seconds < 3600  { return "\(seconds / 60) phút trước" }
            if seconds < 86400 { return "\(seconds / 3600) giờ trước" }
            if days < 8        { return "\(days) ngày trước" }
            if days < 15       { return "1 tuần trước" }
            return Self.shortDateFormatter(locale: "vi_VN", format: "dd/MM/yyyy").string(from: self)
        case .english:
            if seconds < 60    { return "Just now" }
            if seconds < 3600  { return "\(seconds / 60)m ago" }
            if seconds < 86400 { return "\(seconds / 3600)h ago" }
            if days < 8        { return "\(days)d ago" }
            if days < 15       { return "1w ago" }
            return Self.shortDateFormatter(locale: "en_US", format: "MM/dd/yyyy").string(from: self)
        }
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

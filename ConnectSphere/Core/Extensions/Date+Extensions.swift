import Foundation

extension Date {
    /// Chuỗi "thời gian trước" đã localize qua .strings (English key + bản vi).
    var timeAgoString: String {
        let b = Bundle.app
        let seconds = Int(-timeIntervalSinceNow)
        let days = seconds / 86400

        if seconds < 60    { return b.loc("Just now") }
        if seconds < 3600  { return String(format: b.loc("%dm ago"), seconds / 60) }
        if seconds < 86400 { return String(format: b.loc("%dh ago"), seconds / 3600) }
        if days < 8        { return String(format: b.loc("%dd ago"), days) }
        if days < 15       { return b.loc("1w ago") }

        // Ngày tuyệt đối: định dạng theo ngôn ngữ đang chọn
        let isVi = (UserDefaults.standard.string(forKey: "appLanguage") ?? "vi") == "vi"
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

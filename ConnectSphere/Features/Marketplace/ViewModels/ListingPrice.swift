import Foundation

/// A listing's price as the seller types it: whole đồng, digits only.
enum ListingPrice {
    /// Same cap as the server (`ListingStore.maxPrice`).
    static let maxValue: Int64 = 1_000_000_000_000
    static func digits(_ text: String) -> String { text.filter(\.isNumber) }

    /// Empty means free (0); nil when the digits don't fit an Int64.
    static func value(_ text: String) -> Int64? {
        let d = digits(text)
        return d.isEmpty ? 0 : Int64(d)
    }

    /// The price as the field shows it while typing: digits grouped by dots
    /// from the 4th one ("100", "1.000", "150.000"); capped at `maxValue`.
    static func formatted(_ text: String) -> String {
        let d = String(digits(text).drop { $0 == "0" })
        guard !d.isEmpty else { return digits(text).isEmpty ? "" : "0" }
        guard let v = Int64(d) else { return grouped(maxValue) }
        return grouped(min(v, maxValue))
    }

    /// "150.000", VND is written with dots between thousands, whatever the app language.
    static func grouped(_ value: Int64) -> String {
        formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    private static let formatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = "."
        f.usesGroupingSeparator = true
        return f
    }()
}

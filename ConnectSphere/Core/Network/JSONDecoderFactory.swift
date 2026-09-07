import Foundation

extension JSONDecoder {
    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private static let dateOnly: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Decoder for the backend's ISO 8601 dates (with or without fractional
    /// seconds). Resilient by design: an unrecognised or empty string yields
    /// `.distantPast` rather than throwing — one malformed `created_at` must
    /// never fail an entire list payload. (A `null` on a non-optional Date
    /// field still throws; make such fields optional in the DTO.)
    static func makeISO8601() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { dec in
            let str = try dec.singleValueContainer().decode(String.self)
            if let date = isoFractional.date(from: str) { return date }
            if let date = isoPlain.date(from: str) { return date }
            if let date = dateOnly.date(from: str) { return date }
            #if DEBUG
            print("[JSONDecoder] unrecognised date '\(str)' → .distantPast")
            #endif
            return .distantPast
        }
        return d
    }
}

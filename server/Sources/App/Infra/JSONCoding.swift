import Vapor
import Foundation

/// Dates go over the wire as `YYYY-MM-DDTHH:mm:ss.sssZ` (always UTC, always
/// 3 fractional digits), everywhere, so the app parses one format.
enum JSONCoding {
    static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(isoFractional.string(from: date))
        }
        // Keys are not sorted; their order isn't semantically significant.
        e.outputFormatting = [.withoutEscapingSlashes]
        return e
    }

    static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let s = try decoder.singleValueContainer().decode(String.self)
            if let date = isoFractional.date(from: s) { return date }
            let plain = ISO8601DateFormatter()
            if let date = plain.date(from: s) { return date }
            if let date = dateOnly.date(from: s) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad date: \(s)"))
        }
        return d
    }

    static let dateOnly: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// Install as Vapor's default content coders (JSON in/out).
    static func install() {
        ContentConfiguration.global.use(encoder: makeEncoder(), for: .json)
        ContentConfiguration.global.use(decoder: makeDecoder(), for: .json)
    }
}

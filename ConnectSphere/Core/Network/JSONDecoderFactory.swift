import Foundation

extension JSONDecoder {
    /// Returns a decoder pre-configured for the backend's ISO 8601 date format (with optional fractional seconds).
    static func makeISO8601() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { dec in
            let str = try dec.singleValueContainer().decode(String.self)
            let f1 = ISO8601DateFormatter()
            f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = f1.date(from: str) { return date }
            let f2 = ISO8601DateFormatter()
            f2.formatOptions = [.withInternetDateTime]
            if let date = f2.date(from: str) { return date }
            throw DecodingError.dataCorruptedError(
                in: try dec.singleValueContainer(),
                debugDescription: "Unrecognised date format: \(str)"
            )
        }
        return d
    }
}

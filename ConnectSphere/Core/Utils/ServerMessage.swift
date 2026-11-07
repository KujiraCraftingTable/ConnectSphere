import Foundation

/// Translates a reason the server sent. The server answers in English only, so
/// its sentences double as localization keys: a sentence with an entry in the
/// app's language is translated and any other comes back as it was.
/// Sentences with a number in them are matched by shape and rebuilt from a
/// format key, since the number can't be part of a fixed key.
enum ServerMessage {
    static func localized(_ message: String, in bundle: Bundle = .app) -> String {
        let direct = bundle.loc(message)
        if direct != message { return direct }
        for pattern in numbered {
            guard let match = pattern.regex.firstMatch(in: message, range: NSRange(message.startIndex..., in: message)),
                  match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: message),
                  let number = Int(message[range]) else { continue }
            return String(format: bundle.loc(pattern.key(number)), number)
        }
        return message
    }

    private struct Numbered {
        let regex: NSRegularExpression
        let key: (Int) -> String
    }

    /// Server sentences that carry a number (AccountCodeStore).
    private static let numbered: [Numbered] = [
        Numbered(regex: try! NSRegularExpression(pattern: #"^Wait (\d+)s before asking for a new code$"#),
                 key: { _ in "Wait %ds before asking for a new code" }),
        Numbered(regex: try! NSRegularExpression(pattern: #"^That code isn't right, (\d+) tr(?:y|ies) left$"#),
                 key: { $0 == 1 ? "That code isn't right, %d try left" : "That code isn't right, %d tries left" }),
    ]
}

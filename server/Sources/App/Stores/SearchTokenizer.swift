import Foundation

/// Splits a keyword search into the words it is ranked by (people and posts).
///
/// Only letters and digits survive, so a word can never carry SQL LIKE
/// wildcards (`%`, `_`) or regex metacharacters into the ranking SQL. It is
/// still bound as a parameter, this just keeps it inert inside patterns too.
/// Diacritics are kept here on purpose: accent folding ("meo" ↔ "mèo")
/// happens in SQL with `unaccent()` on both sides, so it stays consistent
/// with how the stored text is folded.
enum SearchTokenizer {
    /// Beyond this, extra words add SQL weight without changing the ranking much.
    static let maxWords = 8

    static func words(_ query: String) -> [String] {
        var seen = Set<String>()
        return query.lowercased()
            .split(whereSeparator: { !($0.isLetter || $0.isNumber) })
            .map(String.init)
            .filter { $0.count >= 2 && seen.insert($0).inserted }
            .prefix(maxWords)
            .map { $0 }
    }
}

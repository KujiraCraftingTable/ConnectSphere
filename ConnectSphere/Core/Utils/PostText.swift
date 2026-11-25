import Foundation

/// What a post's own words contain: `#hashtags` and links. Pure, so the
/// composer, the post card and the tests read text the same way.
enum PostText {
    /// `#` at the start of a word, then letters/digits/underscore (any script,
    /// so `#hàNội` works). Not after a letter, digit, `/`, `&` or another `#`,
    /// which keeps `site.com/page#anchor` and `#a#b` from becoming tags.
    private static let tagPattern = try! NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}_/&#])#([\p{L}\p{N}_]+)"#)

    /// Longest tag the server keeps (`PostStore.sanitizeHashtags`).
    private static let maxTagLength = 100

    // MARK: - Hashtags
    /// Tag ranges in `text` (including the `#`); digits-only like `#123` are not tags.
    static func tagRanges(in text: String) -> [Range<String.Index>] {
        let whole = NSRange(text.startIndex..., in: text)
        return tagPattern.matches(in: text, range: whole).compactMap { m in
            guard let word = Range(m.range(at: 1), in: text), text[word].contains(where: \.isLetter),
                  let all = Range(m.range, in: text) else { return nil }
            return all
        }
    }

    /// Tags without the `#`, first spelling kept, duplicates (any case) dropped.
    static func tags(in text: String) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for r in tagRanges(in: text) {
            let tag = String(text[r].dropFirst().prefix(maxTagLength))
            if seen.insert(tag.lowercased()).inserted { out.append(tag) }
        }
        return out
    }

    // MARK: - Links
    /// `text` with each URL removed and the gap closed. A line that held only
    /// a link goes away entirely, so no blank line is left where it was.
    static func removingLinks(from text: String) -> String {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        var kept: [String] = []
        for line in text.components(separatedBy: "\n") {
            var result = line
            let matches = detector?.matches(in: line, range: NSRange(line.startIndex..., in: line)) ?? []
            for m in matches.reversed() {
                if let r = Range(m.range, in: result) { result.removeSubrange(r) }
            }
            if !matches.isEmpty {
                result = result.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
                if result.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            }
            kept.append(result)
        }
        return kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Finished tags
    /// Pulls finished tags (followed by a space or line break, so a tag still
    /// being typed stays put) out of `text`, closing the gap they leave.
    /// `includingTrailing` also takes a tag at the very end, for when the text is final.
    static func extractingFinishedTags(from text: String, includingTrailing: Bool = false) -> (text: String, tags: [String]) {
        var result = text
        var found: [String] = []
        for r in tagRanges(in: text).reversed() {
            let finished = r.upperBound < text.endIndex ? text[r.upperBound].isWhitespace : includingTrailing
            guard finished else { continue }
            found.insert(String(text[r].dropFirst().prefix(maxTagLength)), at: 0)
            // Ranges are applied back to front, so earlier offsets stay valid.
            let lo = result.index(result.startIndex, offsetBy: text.distance(from: text.startIndex, to: r.lowerBound))
            let hi = result.index(result.startIndex, offsetBy: text.distance(from: text.startIndex, to: r.upperBound))
            result.removeSubrange(lo..<hi)
            // A line left empty by the tag goes with its line break.
            let lineStart = result[..<lo].lastIndex(of: "\n").map { result.index(after: $0) } ?? result.startIndex
            let lineEnd = result[lo...].firstIndex(of: "\n") ?? result.endIndex
            if result[lineStart..<lineEnd].allSatisfy({ $0 == " " }) {
                let wasLastLine = lineEnd == result.endIndex
                let end = wasLastLine ? lineEnd : result.index(after: lineEnd)
                result.removeSubrange(lineStart..<end)
                // The last line took no break with it, so drop the one before it.
                if wasLastLine, lineStart > result.startIndex, result[result.index(before: lineStart)] == "\n" {
                    result.remove(at: result.index(before: lineStart))
                }
            } else if lo < result.endIndex, result[lo] == " ",
                      lo == result.startIndex || result[result.index(before: lo)].isWhitespace {
                result.remove(at: lo)
            }
        }
        return (result, found)
    }
}

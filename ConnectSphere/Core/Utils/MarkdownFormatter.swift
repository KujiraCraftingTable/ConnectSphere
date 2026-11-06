import SwiftUI

/// Markdown in user-written text: reading it (`attributed`) and the editing
/// moves behind the composer toolbar (`apply`). Pure, so the post card, the
/// composers and the tests all treat the syntax the same way.
///
/// Supported: **bold**, _italic_, ~~strikethrough~~, `code`, [links](url),
/// `- ` / `1. ` lists and `> ` quotes. Headings, code blocks and images are
/// left as typed on purpose: a heading would shout in a feed, and an inline
/// image would bypass the upload path that strips photo metadata.
enum MarkdownFormatter {
    // MARK: Reading

    /// The text as one styled run. Lists and quotes become lines with a marker
    /// (SwiftUI's `Text` ignores block structure, so they are built here).
    /// Bare URLs are linked too, as they were before Markdown.
    static func attributed(_ text: String, linkColor: Color, quoteColor: Color) -> AttributedString {
        var out = AttributedString()
        let lines = text.components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            if index > 0 { out.append(AttributedString("\n")) }
            out.append(styledLine(line, quoteColor: quoteColor))
        }
        dropUnsafeLinks(in: &out)
        linkBareURLs(in: &out)
        for run in out.runs where run.link != nil {
            out[run.range].foregroundColor = linkColor
        }
        return out
    }

    /// The words alone, for places that cannot show styling (a notification,
    /// a share preview): no `**`, no `_`, links reduced to their label.
    static func plain(_ text: String) -> String {
        String(attributed(text, linkColor: .primary, quoteColor: .primary).characters)
    }

    private static let bulletPattern = try! NSRegularExpression(pattern: #"^(\s*)[-*•]\s+(.*)$"#)
    private static let numberedPattern = try! NSRegularExpression(pattern: #"^(\s*)(\d{1,3})[.)]\s+(.*)$"#)
    private static let quotePattern = try! NSRegularExpression(pattern: #"^\s*>\s?(.*)$"#)

    private static func styledLine(_ line: String, quoteColor: Color) -> AttributedString {
        if let rest = capture(quotePattern, line, group: 1) {
            var quoted = inline(rest)
            quoted.foregroundColor = quoteColor
            var bar = AttributedString("▎ ")
            bar.foregroundColor = quoteColor
            return bar + quoted
        }
        if let rest = capture(bulletPattern, line, group: 2) {
            return AttributedString("•  ") + inline(rest)
        }
        if let number = capture(numberedPattern, line, group: 2), let rest = capture(numberedPattern, line, group: 3) {
            return AttributedString("\(number).  ") + inline(rest)
        }
        return inline(line)
    }

    private static func inline(_ line: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible)
        return (try? AttributedString(markdown: line, options: options)) ?? AttributedString(line)
    }

    private static func capture(_ regex: NSRegularExpression, _ line: String, group: Int) -> String? {
        let whole = NSRange(line.startIndex..., in: line)
        guard let match = regex.firstMatch(in: line, range: whole),
              let range = Range(match.range(at: group), in: line) else { return nil }
        return String(line[range])
    }

    /// Only web, mail and phone links survive; `javascript:` and app schemes
    /// typed into `[text](url)` become plain text.
    private static func dropUnsafeLinks(in text: inout AttributedString) {
        let allowed: Set<String> = ["http", "https", "mailto", "tel"]
        for run in text.runs {
            guard let url = run.link else { continue }
            if !allowed.contains(url.scheme?.lowercased() ?? "") { text[run.range].link = nil }
        }
    }

    private static func linkBareURLs(in text: inout AttributedString) {
        let plain = String(text.characters)
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return }
        for match in detector.matches(in: plain, range: NSRange(plain.startIndex..., in: plain)) {
            guard let url = match.url, let range = Range(match.range, in: plain),
                  let attrRange = Range(range, in: text) else { continue }
            if text[attrRange].runs.contains(where: { $0.link != nil }) { continue }
            text[attrRange].link = url
        }
    }

    // MARK: Editing

    enum Edit: CaseIterable {
        case bold, italic, strikethrough, code, bulletList, quote, link
    }

    /// A text with the part that is selected, as character offsets
    /// (`lowerBound == upperBound` is a caret).
    struct Edited: Equatable {
        var text: String
        var selection: Range<Int>
    }

    /// What a toolbar button does to `text` around `selection`.
    static func apply(_ edit: Edit, to text: String, selection: Range<Int>) -> Edited {
        let chars = Array(text)
        let lower = min(max(selection.lowerBound, 0), chars.count)
        let upper = min(max(selection.upperBound, lower), chars.count)
        switch edit {
        case .bold: return wrap(chars, lower, upper, with: "**")
        case .italic: return wrap(chars, lower, upper, with: "_")
        case .strikethrough: return wrap(chars, lower, upper, with: "~~")
        case .code: return wrap(chars, lower, upper, with: "`")
        case .bulletList: return prefixLines(chars, lower, upper, marker: "- ")
        case .quote: return prefixLines(chars, lower, upper, marker: "> ")
        case .link: return link(chars, lower, upper)
        }
    }

    /// Adds the marker on both sides of the selection, or takes it off when the
    /// selection already sits inside one. A caret gets an empty pair with the
    /// caret between.
    private static func wrap(_ chars: [Character], _ lower: Int, _ upper: Int, with marker: String) -> Edited {
        let m = Array(marker)
        let before = lower >= m.count && Array(chars[(lower - m.count)..<lower]) == m
        let after = upper + m.count <= chars.count && Array(chars[upper..<(upper + m.count)]) == m
        if before && after {
            var next = chars
            next.removeSubrange(upper..<(upper + m.count))
            next.removeSubrange((lower - m.count)..<lower)
            return Edited(text: String(next), selection: (lower - m.count)..<(upper - m.count))
        }
        var next = chars
        next.insert(contentsOf: m, at: upper)
        next.insert(contentsOf: m, at: lower)
        return Edited(text: String(next), selection: (lower + m.count)..<(upper + m.count))
    }

    /// Starts every line the selection touches with `marker`; when they all
    /// have it already, takes it off again.
    private static func prefixLines(_ chars: [Character], _ lower: Int, _ upper: Int, marker: String) -> Edited {
        let m = Array(marker)
        var start = lower
        while start > 0 && chars[start - 1] != "\n" { start -= 1 }
        var end = upper
        while end < chars.count && chars[end] != "\n" { end += 1 }
        let lines = String(chars[start..<end]).components(separatedBy: "\n")
        let allMarked = lines.allSatisfy { $0.hasPrefix(marker) }
        let changed = lines.map { allMarked ? String($0.dropFirst(m.count)) : marker + $0 }.joined(separator: "\n")
        var next = chars
        next.replaceSubrange(start..<end, with: Array(changed))
        let delta = Array(changed).count - (end - start)
        return Edited(text: String(next), selection: start..<(end + delta))
    }

    /// `[selection](https://)` with the address selected, ready to be typed over.
    private static func link(_ chars: [Character], _ lower: Int, _ upper: Int) -> Edited {
        let label = lower == upper ? "link" : String(chars[lower..<upper])
        let address = "https://"
        var next = chars
        next.replaceSubrange(lower..<upper, with: Array("[\(label)](\(address))"))
        let addressStart = lower + label.count + 3
        return Edited(text: String(next), selection: addressStart..<(addressStart + address.count))
    }
}

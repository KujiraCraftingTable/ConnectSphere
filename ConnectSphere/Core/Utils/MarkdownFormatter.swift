import SwiftUI

/// Markdown in user-written text: turns it into styled text (`attributed`) or into
/// plain words (`plain`). Pure, so every screen and the tests treat the syntax the same way.
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

    // MARK: Live styling (while typing)

    /// How one typed character looks in the text box: the words between Markdown
    /// marks are styled, the marks themselves are dimmed but stay visible.
    struct LiveStyle: OptionSet, Equatable {
        let rawValue: Int
        static let bold = LiveStyle(rawValue: 1)
        static let italic = LiveStyle(rawValue: 2)
        static let strike = LiveStyle(rawValue: 4)
        static let code = LiveStyle(rawValue: 8)
        static let link = LiveStyle(rawValue: 16)
        /// A Markdown mark (`**`, `_`, `` ` ``, `[`, `](url)`, a list bullet, `>`).
        static let dim = LiveStyle(rawValue: 32)
        /// The words of a `> ` quote line.
        static let quote = LiveStyle(rawValue: 64)
    }

    private static func regex(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    private static let liveCode = regex(#"`([^`\n]+)`"#)
    private static let liveBold = regex(#"\*\*(?! )([^*\n]+?)(?<! )\*\*"#)
    private static let liveStrike = regex(#"~~(?! )([^~\n]+?)(?<! )~~"#)
    private static let liveItalicUnderscore = regex(#"(?<![\p{L}\p{N}_])_(?![\s_])([^_\n]+?)(?<!\s)_(?![\p{L}\p{N}_])"#)
    private static let liveItalicStar = regex(#"(?<![\p{L}\p{N}*])\*(?![\s*])([^*\n]+?)(?<![\s*])\*(?![\p{L}\p{N}*])"#)
    private static let liveLink = regex(#"\[([^\]\n]+)\]\(([^)\n\s]*)\)"#)
    private static let liveListMarker = regex(#"^[ \t]*([-*•]|\d{1,3}[.)])[ \t]"#, .anchorsMatchLines)
    private static let liveQuote = regex(#"^[ \t]*(>)[ \t]?([^\n]*)$"#, .anchorsMatchLines)

    /// One style per character of `text` (same count as `Array(text)`), so the
    /// text box can color the marks and style the words as they are typed. Unclosed
    /// marks (`**half`) and plain uses of `*` or `_` (`5 * 3`, `snake_case`) get nothing.
    static func liveStyles(in text: String) -> [LiveStyle] {
        let chars = Array(text)
        var styles = [LiveStyle](repeating: [], count: chars.count)
        guard !chars.isEmpty else { return styles }

        // UTF-16 offsets (what NSRegularExpression reports) to character offsets.
        var toChar: [Int] = []
        toChar.reserveCapacity(text.utf16.count + 1)
        for (index, ch) in chars.enumerated() { toChar.append(contentsOf: repeatElement(index, count: ch.utf16.count)) }
        toChar.append(chars.count)
        func span(_ r: NSRange) -> Range<Int> { toChar[r.location]..<toChar[r.location + r.length] }
        func add(_ style: LiveStyle, _ range: Range<Int>) { for i in range { styles[i].formUnion(style) } }

        let whole = NSRange(text.startIndex..., in: text)
        var inCode = [Bool](repeating: false, count: chars.count)

        // Inline pairs: (open mark)(words)(close mark).
        func pairs(_ re: NSRegularExpression, _ style: LiveStyle, skipCode: Bool = true) {
            for m in re.matches(in: text, range: whole) {
                let all = span(m.range), words = span(m.range(at: 1))
                if skipCode && all.contains(where: { inCode[$0] }) { continue }
                add(.dim, all.lowerBound..<words.lowerBound)
                add(.dim, words.upperBound..<all.upperBound)
                add(style, words)
                if style == .code { for i in words { inCode[i] = true } }
            }
        }
        pairs(liveCode, .code, skipCode: false)
        pairs(liveBold, .bold)
        pairs(liveStrike, .strike)
        pairs(liveItalicUnderscore, .italic)
        pairs(liveItalicStar, .italic)

        for m in liveLink.matches(in: text, range: whole) {
            let all = span(m.range), label = span(m.range(at: 1))
            if all.contains(where: { inCode[$0] }) { continue }
            add(.dim, all.lowerBound..<label.lowerBound)
            add(.dim, label.upperBound..<all.upperBound)
            add(.link, label)
        }
        for m in liveListMarker.matches(in: text, range: whole) { add(.dim, span(m.range(at: 1))) }
        for m in liveQuote.matches(in: text, range: whole) {
            add(.dim, span(m.range(at: 1)))
            add(.quote, span(m.range(at: 2)))
        }
        return styles
    }
}

import Foundation

/// The words of a Markdown text without its symbols. Used where only meaning
/// matters (the AI search embedding of a post), so `**sale**` and `sale` end up
/// as the same chunk text. The app does the same on the phone with
/// `MarkdownFormatter.plain`.
enum MarkdownText {
    private static let link = try! NSRegularExpression(pattern: #"\[([^\]\n]*)\]\([^)\n]*\)"#)
    private static let pairs = try! NSRegularExpression(pattern: #"\*\*|__|~~|`"#)
    private static let emphasis = try! NSRegularExpression(pattern: #"(?<![\p{L}\p{N}])[*_]([^*_\n]+)[*_](?![\p{L}\p{N}])"#)
    private static let listMarker = try! NSRegularExpression(pattern: #"^[ \t]*(?:[-*•]|\d{1,3}[.)])[ \t]+"#, options: .anchorsMatchLines)
    private static let quoteMarker = try! NSRegularExpression(pattern: #"^[ \t]*>[ \t]?"#, options: .anchorsMatchLines)

    static func plain(_ text: String) -> String {
        var out = text
        out = replace(link, in: out, with: "$1")
        out = replace(pairs, in: out, with: "")
        out = replace(emphasis, in: out, with: "$1")
        out = replace(listMarker, in: out, with: "")
        out = replace(quoteMarker, in: out, with: "")
        return out
    }

    private static func replace(_ regex: NSRegularExpression, in text: String, with template: String) -> String {
        regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }
}

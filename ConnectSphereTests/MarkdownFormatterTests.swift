import SwiftUI
import Testing
@testable import ConnectSphere

struct MarkdownFormatterTests {
    private func plain(_ text: String) -> String { MarkdownFormatter.plain(text) }

    // MARK: Reading

    @Test func inlineStylesLoseTheirSymbols() {
        #expect(plain("**bold** and _italic_ and ~~gone~~ and `code`") == "bold and italic and gone and code")
    }

    @Test func linksShowOnlyTheirLabel() {
        #expect(plain("see [the docs](https://example.com/a)") == "see the docs")
    }

    @Test func markdownLinkBecomesATappableRun() {
        let text = MarkdownFormatter.attributed("[docs](https://example.com)", linkColor: .blue, quoteColor: .gray)
        let urls = text.runs.compactMap(\.link)
        #expect(urls == [URL(string: "https://example.com")!])
    }

    @Test func unsafeSchemesAreNotLinked() {
        let text = MarkdownFormatter.attributed("[click](javascript:alert(1)) [app](myapp://x)", linkColor: .blue, quoteColor: .gray)
        #expect(text.runs.compactMap(\.link).isEmpty)
    }

    @Test func bareURLsStillBecomeLinks() {
        let text = MarkdownFormatter.attributed("go to https://example.com now", linkColor: .blue, quoteColor: .gray)
        #expect(text.runs.compactMap(\.link) == [URL(string: "https://example.com")!])
    }

    @Test func listsAndQuotesGetMarkers() {
        #expect(plain("- one\n- two") == "•  one\n•  two")
        #expect(plain("1. first\n2) second") == "1.  first\n2.  second")
        #expect(plain("> wise words") == "▎ wise words")
    }

    @Test func ordinaryTextKeepsItsLineBreaks() {
        #expect(plain("line one\n\nline three") == "line one\n\nline three")
    }

    @Test func unclosedMarkersDoNotBreakTheText() {
        #expect(plain("5 * 3 = 15 and **half").contains("15"))
    }

    // MARK: Live styling

    private func live(_ text: String) -> [MarkdownFormatter.LiveStyle] { MarkdownFormatter.liveStyles(in: text) }

    @Test func boldWordsAreBoldAndTheStarsAreDimmed() {
        let s = live("**B**")
        #expect(s.count == 5)
        #expect(s[0] == .dim && s[1] == .dim)
        #expect(s[2] == .bold)
        #expect(s[3] == .dim && s[4] == .dim)
    }

    @Test func otherInlineStylesGetTheirOwnStyle() {
        #expect(live("_i_") == [.dim, .italic, .dim])
        #expect(live("*i*") == [.dim, .italic, .dim])
        #expect(live("~~s~~") == [.dim, .dim, .strike, .dim, .dim])
        #expect(live("`c`") == [.dim, .code, .dim])
    }

    @Test func linksDimTheBracketsAndAddressButNotTheLabel() {
        let s = live("[a](https://x.com)")
        #expect(s[0] == .dim)
        #expect(s[1] == .link)
        #expect(s[2...].allSatisfy { $0 == .dim })
    }

    @Test func listAndQuoteMarksAreDimmedAndQuoteWordsStandOut() {
        #expect(live("- item")[0] == .dim)
        #expect(live("- item")[2] == [])
        #expect(live("12. item")[0] == .dim && live("12. item")[1] == .dim && live("12. item")[2] == .dim)
        let q = live("> hi")
        #expect(q[0] == .dim)
        #expect(q[2] == .quote && q[3] == .quote)
    }

    @Test func styleCombinesWhenMarksAreNested() {
        let s = live("**a _b_ c**")
        #expect(s[5] == [.bold, .italic])
    }

    @Test func unclosedMarksAndPlainSymbolsAreLeftAlone() {
        #expect(live("**half").allSatisfy { $0.isEmpty })
        #expect(live("5 * 3 = 15").allSatisfy { $0.isEmpty })
        #expect(live("use snake_case_name here").allSatisfy { $0.isEmpty })
    }

    @Test func marksInsideCodeAreNotStyled() {
        let s = live("`**x**`")
        #expect(s[1] == .code && s[2] == .code && s[3] == .code)
    }

    @Test func emojiAndVietnameseBeforeAMarkKeepOffsetsRight() {
        let s = live("😀 **B**")
        #expect(s.count == 7)
        #expect(s[4] == .bold)
        let v = live("Xin chào **B**")
        #expect(v[10] == .bold)
    }
}

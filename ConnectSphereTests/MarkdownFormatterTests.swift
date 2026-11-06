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

    // MARK: Editing

    @Test func boldWrapsTheSelection() {
        let r = MarkdownFormatter.apply(.bold, to: "make this loud", selection: 5..<9)
        #expect(r.text == "make **this** loud")
        #expect(r.selection == 7..<11)
    }

    @Test func boldAtACaretInsertsAPairAroundIt() {
        let r = MarkdownFormatter.apply(.bold, to: "hi ", selection: 3..<3)
        #expect(r.text == "hi ****")
        #expect(r.selection == 5..<5)
    }

    @Test func boldTwiceTakesTheMarkersOff() {
        let on = MarkdownFormatter.apply(.bold, to: "word", selection: 0..<4)
        let off = MarkdownFormatter.apply(.bold, to: on.text, selection: on.selection)
        #expect(off.text == "word")
        #expect(off.selection == 0..<4)
    }

    @Test func listPrefixesEveryTouchedLineAndTogglesOff() {
        let on = MarkdownFormatter.apply(.bulletList, to: "a\nb\nc", selection: 0..<3)
        #expect(on.text == "- a\n- b\nc")
        let off = MarkdownFormatter.apply(.bulletList, to: on.text, selection: on.selection)
        #expect(off.text == "a\nb\nc")
    }

    @Test func quotePrefixesTheCaretLine() {
        let r = MarkdownFormatter.apply(.quote, to: "one\ntwo", selection: 5..<5)
        #expect(r.text == "one\n> two")
    }

    @Test func linkWrapsTheSelectionAndSelectsTheAddress() {
        let r = MarkdownFormatter.apply(.link, to: "read docs here", selection: 5..<9)
        #expect(r.text == "read [docs](https://) here")
        let chars = Array(r.text)
        #expect(String(chars[r.selection]) == "https://")
    }

    @Test func linkWithNothingSelectedStartsFromAPlaceholder() {
        let r = MarkdownFormatter.apply(.link, to: "", selection: 0..<0)
        #expect(r.text == "[link](https://)")
    }

    @Test func editingHandlesEmojiAsOneCharacter() {
        let r = MarkdownFormatter.apply(.bold, to: "😀 hi", selection: 2..<4)
        #expect(r.text == "😀 **hi**")
    }
}

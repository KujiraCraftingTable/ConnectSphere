import Foundation
import Testing
@testable import ConnectSphere

struct PostTextTests {
    @Test func findsTagsInAnyScript() {
        #expect(PostText.tags(in: "đi chơi #hàNội và #music_live!") == ["hàNội", "music_live"])
    }

    @Test func ignoresAnchorsAndDigitsOnly() {
        #expect(PostText.tags(in: "https://a.com/page#anchor #123 word#tag").isEmpty)
    }

    @Test func chainedTagKeepsTheFirstOnly() {
        #expect(PostText.tags(in: "#a#b") == ["a"])
    }

    @Test func dropsDuplicatesAnyCase() {
        #expect(PostText.tags(in: "#Music again #music") == ["Music"])
    }

    @Test func removesLinksAndClosesTheGap() {
        let text = "i love this song https://m.youtube.com/watch?v=abc&list=x so bad"
        #expect(PostText.removingLinks(from: text) == "i love this song so bad")
        #expect(PostText.removingLinks(from: "https://example.com") == "")
        // The link's own line leaves no blank line; the user's own blank line stays.
        #expect(PostText.removingLinks(from: "love this\nhttps://example.com/a\n#tag") == "love this\n#tag")
        #expect(PostText.removingLinks(from: "a\n\nb\nhttps://example.com/a") == "a\n\nb")
    }

    @Test func extractsOnlyFinishedTags() {
        let a = PostText.extractingFinishedTags(from: "love #music this #hanoi")
        #expect(a.text == "love this #hanoi")
        #expect(a.tags == ["music"])
        let b = PostText.extractingFinishedTags(from: "a\n#x\nb")
        #expect(b.text == "a\nb")
        #expect(PostText.extractingFinishedTags(from: "#tag ").text == "")
        // A tag typed last counts once the text is final.
        let c = PostText.extractingFinishedTags(from: "Text mix content\n\n#lemon", includingTrailing: true)
        #expect(c.tags == ["lemon"])
        #expect(c.text.trimmingCharacters(in: .whitespacesAndNewlines) == "Text mix content")
        #expect(PostText.extractingFinishedTags(from: "a #lemon").tags.isEmpty)
        // The tag's own line goes away with its line break.
        #expect(PostText.extractingFinishedTags(from: "love this\n#hashtag \nso good").text == "love this\nso good")
    }
}

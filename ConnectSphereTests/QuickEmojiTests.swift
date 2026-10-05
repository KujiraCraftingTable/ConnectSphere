import Testing
@testable import ConnectSphere

struct QuickEmojiTests {
    @Test func acceptsEverydayEmoji() {
        for e in ["👍", "😂", "🔥", "🐴", "❤️"] {
            #expect(QuickEmoji.emoji(in: e) == e, "\(e)")
        }
    }

    @Test func keepsMultiScalarEmojiWhole() {
        // Skin tone, ZWJ sequence, flag, keycap.
        for e in ["👍🏽", "👩‍💻", "🇻🇳", "1️⃣"] {
            #expect(QuickEmoji.emoji(in: e) == e, "\(e)")
        }
    }

    @Test func rejectsTextThatMerelyCarriesTheEmojiFlag() {
        for s in ["a", "1", "#", "©", "™"] {
            #expect(QuickEmoji.emoji(in: s) == nil, "\(s)")
        }
    }

    @Test func takesTheLastCharacterOnly() {
        #expect(QuickEmoji.emoji(in: "hi😂") == "😂")
        #expect(QuickEmoji.emoji(in: "😂hi") == nil)
        #expect(QuickEmoji.emoji(in: "") == nil)
    }
}

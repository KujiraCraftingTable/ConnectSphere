import Foundation
import Testing
@testable import ConnectSphere

@MainActor
struct TranslationTests {
    @Test func offeredOnlyForTheOtherOfEnglishAndVietnamese() {
        #expect(ContentTranslation.isAvailable(lang: "vi", translated: "Hello", appLanguage: .english))
        #expect(!ContentTranslation.isAvailable(lang: "vi", translated: "Hello", appLanguage: .vietnamese))   // already in it
        #expect(ContentTranslation.isAvailable(lang: "en", translated: "Xin chào", appLanguage: .vietnamese))
        #expect(!ContentTranslation.isAvailable(lang: "other", translated: "x", appLanguage: .english))      // Japanese etc.
        #expect(!ContentTranslation.isAvailable(lang: "vi", translated: nil, appLanguage: .english))         // not made yet
        #expect(!ContentTranslation.isAvailable(lang: "vi", translated: "  ", appLanguage: .english))
        #expect(!ContentTranslation.isAvailable(lang: nil, translated: "x", appLanguage: .english))
    }

    @Test func eachItemFlipsAwayFromTheSettingIndependently() {
        let store = TranslationStore()
        let a = TranslationStore.key(post: "P1"), b = TranslationStore.key(comment: "c1")
        #expect(!store.showsTranslation(a, mode: .original))
        #expect(store.showsTranslation(a, mode: .translated))
        store.toggle(a)
        #expect(store.showsTranslation(a, mode: .original))      // "Show translation" tapped
        #expect(!store.showsTranslation(a, mode: .translated))   // with translations on, it shows the original
        #expect(!store.showsTranslation(b, mode: .original))     // others untouched
        store.toggle(a)
        #expect(!store.showsTranslation(a, mode: .original))
        #expect(TranslationStore.key(post: "P1") == TranslationStore.key(post: "p1"))
    }

    @Test func postsAndCommentsDecodeTheirTranslation() throws {
        let post = try JSONDecoder.makeISO8601().decode(PostDTO.self, from: Data("""
            {"id":"p1","content":"Xin chào","mode":"hobby","privacy":"public","created_at":"2026-10-13T09:00:00.000Z",
             "like_count":0,"comment_count":0,"share_count":0,"post_type":"text","is_liked":false,"is_saved":false,"tags":[],
             "lang":"vi","translated_text":"Hello","author":{"id":"u1","username":"a","display_name":"A","avatar_color":"#111111"}}
            """.utf8)).toPost()
        #expect(post.contentLang == "vi" && post.translatedContent == "Hello")
        let comments = try JSONDecoder.makeISO8601().decode([CommentDTO].self, from: Data("""
            [{"id":"c1","content":"Great","created_at":"2026-10-13T09:00:00.000Z","lang":"en","translated_text":"Tuyệt",
              "author":{"id":"u1","display_name":"A","avatar_color":"#111111"}}]
            """.utf8))
        #expect(comments[0].lang == "en" && comments[0].translatedText == "Tuyệt")
    }
}

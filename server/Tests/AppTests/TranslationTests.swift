import XCTest
@testable import App

final class TranslationTests: XCTestCase {
    func testDetectsEnglishVietnameseAndOthers() {
        XCTAssertEqual(TranslationService.detectLanguage("Vừa cày xong Jujutsu Kaisen. Arc mới đỉnh thật sự 😭🔥"), "vi")
        XCTAssertEqual(TranslationService.detectLanguage("mình thích nghe nhạc jpop"), "vi")
        XCTAssertEqual(TranslationService.detectLanguage("I love eating jolibee"), "en")
        XCTAssertEqual(TranslationService.detectLanguage("We had phở for lunch, it was great"), "en")   // one borrowed word
        XCTAssertEqual(TranslationService.detectLanguage("今日はとても楽しかったです"), "other")
        XCTAssertNil(TranslationService.detectLanguage("😭🔥 https://youtu.be/x #jpop"))             // nothing to translate
        XCTAssertNil(TranslationService.detectLanguage("ok"))
        // Decomposed accents (some keyboards) still read as Vietnamese.
        XCTAssertEqual(TranslationService.detectLanguage("Ve\u{0302}\u{0300} nha\u{0300} tho\u{0302}i ca\u{0301}c ba\u{0323}n"), "vi")
    }

    func testModelWrappersAreStripped() {
        XCTAssertEqual(TranslationService.cleanOutput("Translation: Hello there", source: "Xin chào"), "Hello there")
        XCTAssertEqual(TranslationService.cleanOutput("\"Hello there\"\n", source: "Xin chào"), "Hello there")
        XCTAssertEqual(TranslationService.cleanOutput("“Xin chào”", source: "“Hello”"), "“Xin chào”")   // the source was quoted too
        XCTAssertEqual(TranslationService.cleanOutput("Ay do he he he\nMeow meow /no_think", source: "x"), "Ay do he he he\nMeow meow")
        XCTAssertEqual(TranslationService.cleanOutput("Okay, this is to check translation /no_translate", source: "Ok cái này là để kiểm tra dịch thuật"),
                       "Okay, this is to check translation")
        // The writer's own trailing command stays.
        XCTAssertEqual(TranslationService.cleanOutput("Gõ /help", source: "Type /help"), "Gõ /help")
        XCTAssertEqual(TranslationService.cleanOutput("<think>\nuser wants EN\n</think>\n\nHello there", source: "Xin chào"), "Hello there")
    }

    func testHashMatchesSQLsHex() {
        XCTAssertEqual(TranslationService.hash(""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(TranslationService.hash("chết").count, 64)
        XCTAssertNotEqual(TranslationService.hash("a"), TranslationService.hash("a "))
    }
}

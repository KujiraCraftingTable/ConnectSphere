import XCTest
@testable import App

final class WikipediaTitleTests: XCTestCase {
    func testFirstOpenSearchTitle() {
        let body = #"["Kimishinu",["KimiShinu","Tatsumi Kimishima"],["",""],["https://en.wikipedia.org/wiki/KimiShinu",""]]"#
        XCTAssertEqual(WikipediaService.firstOpenSearchTitle(Data(body.utf8)), "KimiShinu")
    }

    func testNoTitleWhenNothingFound() {
        XCTAssertNil(WikipediaService.firstOpenSearchTitle(Data(#"["zzqx",[],[],[]]"#.utf8)))
        XCTAssertNil(WikipediaService.firstOpenSearchTitle(Data("not json".utf8)))
    }
}

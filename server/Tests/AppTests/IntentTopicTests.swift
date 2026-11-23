@testable import App
import XCTest

final class IntentTopicTests: XCTestCase {
    func testTopicIsWhatIsLeftOfTheRestatement() {
        XCTAssertEqual(IntentTopic.topic(in: "find people interested in beekeeping"), "beekeeping")
        XCTAssertEqual(IntentTopic.topic(in: "find beekeepers who make honey"), "beekeepers make honey")
        XCTAssertEqual(IntentTopic.topic(in: "Find friends who love woodworking and beekeeping"), "woodworking beekeeping")
    }

    func testNoTopicWhenOnlySearchWordsOrASentence() {
        XCTAssertNil(IntentTopic.topic(in: "find people"))
        XCTAssertNil(IntentTopic.topic(in: "find a friend for me"))
        XCTAssertNil(IntentTopic.topic(in: "find someone who could help me move my sofa across town next week"))
    }

    func testConceptCarriesTheTopic() {
        let c = IntentTopic.concept(in: "find people interested in beekeeping")
        XCTAssertEqual(c?.label, "beekeeping")
        XCTAssertEqual(c?.vectorText, "beekeeping")
    }

    func testReadingWithoutTopicNamesNothing() {
        var c = OllamaService.SearchCriteria(
            intent_en: "find people interested in beekeeping", entity_keywords: [], interest_groups: [], interests: [],
            skills: [], bio_keywords: [], job_title_keywords: [], mode: "hobby")
        XCTAssertTrue(c.namesNothing)
        c.interest_groups = [["beekeeping"]]
        XCTAssertFalse(c.namesNothing)
        c.interest_groups = []
        c.location = "Hanoi"
        XCTAssertFalse(c.namesNothing)
    }
}

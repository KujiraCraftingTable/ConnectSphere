@testable import App
import XCTest

/// AI_SEARCH_REVIEW.md, phase S6: the prompt is the gate. Built from the
/// prompts real testers typed ("hút thuốc", "chém gió", "thích 67", "1m8").
final class SearchConceptTests: XCTestCase {
    static func entry(_ name: String, _ aliases: [String], parent: String? = nil, category: String = "x",
                      specific: Bool = false, picks: Int = 0) -> InterestStore.Entry {
        InterestStore.Entry(id: name, name_en: name, name_vi: name, category: category, parent_id: parent,
                            aliases: aliases, allows_specific: specific, pick_count: picks)
    }

    /// A slice of migration 080.
    static let catalog: [InterestStore.Entry] = [
        entry("Sports", ["thể thao", "sport", "sports"], category: "sports"),
        entry("Football", ["bóng đá", "đá banh", "soccer", "football"], parent: "Sports", category: "sports"),
        entry("Swimming", ["bơi lội", "bơi", "swimming"], parent: "Sports", category: "sports"),
        entry("Movies", ["xem phim", "phim", "film", "movies"], category: "film", specific: true),
        entry("Photography", ["chụp ảnh", "photography"], category: "arts"),
        entry("Film photography", ["chụp ảnh film", "film photography"], parent: "Photography", category: "arts"),
        entry("Anime", ["xem anime", "anime"], category: "anime", specific: true),
        entry("Gaming", ["chơi game", "game", "gaming"], category: "games", specific: true),
        entry("Roblox", ["roblox"], parent: "Gaming", category: "games"),
        entry("Smoking", ["hút thuốc", "hút thuốc lá", "thuốc lá", "smoking", "smoke"], category: "lifestyle"),
        entry("Chatting / Banter", ["chém gió", "tám chuyện", "chatting", "banter"], category: "lifestyle"),
    ]

    private func criteria(groups: [[String]] = [], entity: String? = nil, entityType: String? = nil,
                          bio: [String] = []) -> OllamaService.SearchCriteria {
        OllamaService.SearchCriteria(
            intent_en: "", target_gender: nil, target_age_min: nil, target_age_max: nil,
            entity_type: entityType, entity_name: entity, entity_keywords: [], interest_groups: groups,
            interests: groups.flatMap { $0 }, skills: [], bio_keywords: bio, job_title_keywords: [],
            location: nil, place_name: nil, mode: "hobby")
    }

    private func concepts(_ prompt: String, _ c: OllamaService.SearchCriteria? = nil) -> [SearchConcepts.Concept] {
        SearchConcepts.concepts(prompt: prompt, criteria: c ?? criteria(), entries: Self.catalog)
    }

    // MARK: Topics named in the prompt

    /// qwen returned no interest for these; the catalogue still finds them.
    func testSlangAndHabitsTheLLMDroppedAreFound() {
        let smoking = concepts("tìm bạn nam thích hút thuốc")
        XCTAssertEqual(smoking.map(\.label), ["hút thuốc"])
        XCTAssertEqual(smoking.first?.declared, ["smoking"])
        XCTAssertEqual(concepts("tìm bạn nữ thích chém gió").first?.declared, ["chatting / banter"])
    }

    func testUnaccentedPhrasesStillMatch() {
        XCTAssertEqual(concepts("tim ban thich hut thuoc").first?.declared, ["smoking"])
    }

    /// Folded single words collide: "bói" (fortune telling) isn't "bơi".
    func testSingleWordsNeedTheirAccents() {
        XCTAssertTrue(concepts("tìm bạn thích xem bói").isEmpty)
        XCTAssertEqual(concepts("tìm bạn thích bơi").first?.declared, ["swimming"])
    }

    func testTheLongestPhraseWins() {
        XCTAssertEqual(concepts("bạn thích chụp ảnh film").map(\.vectorText), ["Film photography"])
    }

    /// Asking for Sports includes football fans; asking for football never
    /// includes people who only said Sports.
    func testParentsIncludeChildrenButNotTheReverse() {
        XCTAssertTrue(concepts("bạn thích thể thao").first!.declared.contains("football"))
        XCTAssertFalse(concepts("bạn thích đá banh").first!.declared.contains("sports"))
    }

    func testTwoTopicsStayTwo() {
        XCTAssertEqual(concepts("bạn thích anime và bóng đá").count, 2)
    }

    func testTheLLMsTopicsJoinTheCatalogues() {
        let c = concepts("someone into Kimetsu no Yaiba",
                         criteria(groups: [["anime", "manga"]], entity: "Kimetsu no Yaiba", entityType: "anime"))
        // The entity's own kind ("anime") isn't a second topic.
        XCTAssertEqual(c.map(\.label), ["Kimetsu no Yaiba"])
        let same = concepts("bạn thích đá banh", criteria(groups: [["football", "soccer"]]))
        XCTAssertEqual(same.count, 1)
    }

    func testNumbersAndPersonWordsNameNothing() {
        XCTAssertTrue(concepts("tìm bạn thích số 67", criteria(groups: [["67"]])).isEmpty)
        XCTAssertTrue(concepts("người iu nam", criteria(bio: ["friend", "1.8 meters"])).isEmpty)
    }

    // MARK: What people search doesn't do

    func testHeightWeightAndLooksAreUnsupported() {
        XCTAssertEqual(SearchConcepts.unsupportedTrait("tìm bạn nam cao 1m8"), "1m8")
        XCTAssertEqual(SearchConcepts.unsupportedTrait("bạn nữ 1m7"), "1m7")
        XCTAssertEqual(SearchConcepts.unsupportedTrait("bạn nặng 50kg"), "50kg")
        XCTAssertEqual(SearchConcepts.unsupportedTrait("một bạn đẹp trai"), "đẹp trai")
        XCTAssertNil(SearchConcepts.unsupportedTrait("tìm bạn thích số 89"))
        XCTAssertNil(SearchConcepts.unsupportedTrait("bạn thích chạy 10 km"))
    }

    func testPartnerWordsAreDroppedAndTheRestIsSearched() {
        XCTAssertEqual(SearchConcepts.withoutPartnerWords("looking for a men to date in hcmc"), "looking for a men in hcmc")
        XCTAssertEqual(SearchConcepts.withoutPartnerWords("tìm người yêu nam ở Hà Nội"), "tìm nam ở Hà Nội")
        XCTAssertEqual(SearchConcepts.withoutPartnerWords("tìm người yêu"), "tìm")
        for q in ["người iu nam 1m8", "tìm ny ở Hà Nội", "kiếm bồ", "looking for a girlfriend", "nguoi yeu nu"] {
            XCTAssertTrue(SearchConcepts.mentionsPartner(q), q)
        }
        for q in ["tìm bạn nữ thích chém gió", "tìm bộ phim hay", "study partner for IELTS",
                  "people who love football", "bạn nữ yêu thích mèo", "update my profile"] {
            XCTAssertFalse(SearchConcepts.mentionsPartner(q), q)
            XCTAssertEqual(SearchConcepts.withoutPartnerWords(q), q.split(separator: " ").joined(separator: " "), q)
        }
    }

    /// "thích 8" was read as "aged 16 or under".
    func testABareNumberIsNotAnAge() {
        XCTAssertFalse(SearchConcepts.mentionsAge("tìm bạn nam thích 8"))
        XCTAssertFalse(SearchConcepts.mentionsAge("tìm bạn thích số 89"))
        XCTAssertTrue(SearchConcepts.mentionsAge("bạn nữ 20 tuổi"))
        XCTAssertTrue(SearchConcepts.mentionsAge("someone over 25 years old"))
        XCTAssertTrue(SearchConcepts.mentionsAge("bạn 9x thích anime"))
    }

    func testASkillAliasFindsTheCatalogueSkill() {
        let skills = [Self.entry("JavaScript", ["javascript", "js"], category: "web"),
                      Self.entry("React", ["react", "reactjs"], parent: "JavaScript", category: "web")]
        let found = SearchConcepts.concepts(prompt: "tìm dev reactjs ở HCM", criteria: criteria(), entries: skills)
        XCTAssertEqual(found.map(\.declared), [["react"]])
        // A search for the parent includes people who list the child.
        let parent = SearchConcepts.concepts(prompt: "javascript developer", criteria: criteria(), entries: skills)
        XCTAssertEqual(parent.first?.declared, ["javascript", "react"])
    }

    // MARK: topics in English, posts about any topic

    func testTopicLeftInVietnameseGetsItsEnglishWords() {
        let c = SearchConcepts.Concept(label: "chó", terms: ["chó"], declared: ["chó"], vectorText: "chó")
        XCTAssertTrue(SearchConcepts.needsEnglish(c))
        let en = SearchConcepts.inEnglish(c, translation: " Dog, puppy \n")
        XCTAssertEqual(en.label, "chó")
        XCTAssertEqual(en.vectorText, "Dog, puppy")
        XCTAssertEqual(en.terms, ["Dog", "puppy", "chó"])
        XCTAssertEqual(en.declared, ["dog", "puppy", "chó"])
    }

    func testEnglishTopicAndBadTranslationAreLeftAlone() {
        let dog = SearchConcepts.Concept(label: "dog", terms: ["dog"], declared: ["dog"], vectorText: "dog")
        XCTAssertFalse(SearchConcepts.needsEnglish(dog))
        let cho = SearchConcepts.Concept(label: "chó", terms: ["chó"], declared: ["chó"], vectorText: "chó")
        XCTAssertEqual(SearchConcepts.inEnglish(cho, translation: ""), cho)
        XCTAssertEqual(SearchConcepts.inEnglish(cho, translation: "chó"), cho)
        XCTAssertEqual(SearchConcepts.inEnglish(cho, translation: String(repeating: "The word means dog. ", count: 5)), cho)
    }

    func testPostAboutOneTopicIsFoundAndCriteriaAreCounted() {
        let m = SearchConcepts.postMatches([["a": 0.7, "b": 0.7], ["b": 0.66], [:]], inPlace: ["a", "z"])
        XCTAssertEqual(Set(m.keys), ["a", "b"])               // "z" is only about the place
        XCTAssertEqual(m["a"], .init(match: 0.7, criteria: 2))  // one topic + the place
        XCTAssertEqual(m["b"]!.match, 0.68, accuracy: 1e-9)
        XCTAssertEqual(m["b"]!.criteria, 2)                     // two topics
        XCTAssertTrue(SearchConcepts.postMatches([[:], [:]]).isEmpty)
    }

    func testPromptWithOnlyAPlaceIsThePostsAboutIt() {
        XCTAssertEqual(SearchConcepts.postMatches([], inPlace: ["z"]), ["z": .init(match: 0, criteria: 1)])
        XCTAssertTrue(SearchConcepts.postMatches([], inPlace: nil).isEmpty)
    }

    // MARK: post search elements

    func testPostQueryIsBoundedAndTrimmed() {
        let q = OllamaService.cleanPostQuery(
            topics: [[" sunset over the sea ", "", "a", "b", "c"], [], ["1"], ["2"], ["3"], ["4"]],
            place: " bình thạnh, ")
        XCTAssertEqual(q.topics, [["sunset over the sea", "a", "b"], ["1"], ["2"], ["3"]])
        XCTAssertEqual(q.place, "bình thạnh")
        XCTAssertNil(OllamaService.cleanPostQuery(topics: [], place: " ").place)
    }

    func testPhraseTopicHasALowerBarThanAWord() {
        func c(_ text: String) -> SearchConcepts.Concept { .init(label: text, terms: [text], declared: [], vectorText: text) }
        XCTAssertEqual(SearchConcepts.postMin(for: c("dog, puppy")), SearchConcepts.conceptPostMin)
        XCTAssertEqual(SearchConcepts.postMin(for: c("grilled meat")), SearchConcepts.conceptPostMin)
        XCTAssertEqual(SearchConcepts.postMin(for: c("sunset over the sea, sunset at the beach")), SearchConcepts.phrasePostMin)
    }

    // MARK: distance in the prompt

    func testDistanceAskedForInThePrompt() {
        XCTAssertEqual(SearchConcepts.distanceKm("tìm bạn ở bình thạnh trong vòng 3 km"), 3)
        XCTAssertEqual(SearchConcepts.distanceKm("ban kinh 5km quanh quan 1"), 5)
        XCTAssertEqual(SearchConcepts.distanceKm("friends within 10 km of Thu Duc"), 10)
        XCTAssertEqual(SearchConcepts.distanceKm("bạn thích cà phê 2,5 km quanh đây"), 2.5)
        XCTAssertEqual(SearchConcepts.distanceKm("trong vòng 500 km"), 50)
        XCTAssertEqual(SearchConcepts.distanceKm("dưới 0.2 km"), 1)
    }

    func testANumberOfKmAloneIsNotADistanceLimit() {
        XCTAssertNil(SearchConcepts.distanceKm("bạn thích chạy 5km mỗi sáng"))
        XCTAssertNil(SearchConcepts.distanceKm("tìm bạn ở gò vấp"))
        XCTAssertNil(SearchConcepts.distanceKm("gần 45 lê thánh tôn"))
    }

    func testDistanceIsTakenOutBeforeThePlaceIsRead() {
        XCTAssertEqual(SearchConcepts.withoutDistance("tìm bạn ở gò vấp trong vòng 3 km"), "tìm bạn ở gò vấp")
        XCTAssertEqual(SearchConcepts.withoutDistance("friends within 10 km of thu duc"), "friends of thu duc")
        XCTAssertEqual(SearchConcepts.withoutDistance("thích chạy 5km ở gò vấp"), "thích chạy 5km ở gò vấp")
    }
}

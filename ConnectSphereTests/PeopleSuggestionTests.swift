import Foundation
import Testing
@testable import ConnectSphere

@MainActor
struct PeopleSuggestionTests {
    @Test func freshSuggestionsGoFirstOtherwiseAFewPostsIn() {
        #expect(SuggestionPlacement.slots(isFresh: true, postCount: 20, suggestionCount: 5, seed: 0) == [0, 10])
        for seed in UInt64(0)..<64 {
            let slots = SuggestionPlacement.slots(isFresh: false, postCount: 40, suggestionCount: 5, seed: seed)
            #expect(slots.count == 2)
            #expect((3...6).contains(slots[0]))
            #expect((10...13).contains(slots[1] - slots[0]))
        }
    }

    @Test func neverMoreThanTheFeedOrWhenThereIsNothingToShow() {
        #expect(SuggestionPlacement.slots(isFresh: false, postCount: 5, suggestionCount: 5, seed: 0) == [3])
        #expect(SuggestionPlacement.slots(isFresh: true, postCount: 1, suggestionCount: 5, seed: 0) == [0])
        #expect(SuggestionPlacement.slots(isFresh: true, postCount: 20, suggestionCount: 0, seed: 0).isEmpty)
        #expect(SuggestionPlacement.slots(isFresh: true, postCount: 0, suggestionCount: 5, seed: 0).isEmpty)
        // Same seed, same layout: the module doesn't jump while you scroll.
        #expect(SuggestionPlacement.slots(isFresh: false, postCount: 30, suggestionCount: 3, seed: 7)
                == SuggestionPlacement.slots(isFresh: false, postCount: 30, suggestionCount: 3, seed: 7))
    }

    private func decode(_ reason: String) throws -> PeopleSuggestion.Reason {
        let json = #"{"id":"u1","username":"lan","display_name":"Lan","mutual_count":2,"reason":\#(reason)}"#
        return try JSONDecoder().decode(PeopleSuggestion.self, from: Data(json.utf8)).reason
    }

    @Test func reasonsDecodeAndUnknownOnesFallBackToSimilar() throws {
        #expect(try decode(#"{"kind":"mutual","count":3}"#) == .mutual(3))
        #expect(try decode(#"{"kind":"interest","value":"jpop"}"#) == .interest("jpop"))
        #expect(try decode(#"{"kind":"skill","value":"Swift"}"#) == .skill("Swift"))
        #expect(try decode(#"{"kind":"company","value":"Grab"}"#) == .company("Grab"))
        #expect(try decode(#"{"kind":"place","value":"Huế"}"#) == .place("Huế"))
        #expect(try decode(#"{"kind":"similar"}"#) == .similar)
        #expect(try decode(#"{"kind":"astrology","value":"Leo"}"#) == .similar)
        #expect(try decode(#"{"kind":"interest"}"#) == .similar)
    }

    @Test func cardTextReadsNaturally() {
        let en = Bundle.main
        #expect(PeopleSuggestionText.reason(.mutual(1), mode: .hobby, bundle: en) == "1 mutual friend")
        #expect(PeopleSuggestionText.reason(.mutual(4), mode: .hobby, bundle: en) == "4 mutual friends")
        #expect(PeopleSuggestionText.reason(.interest("jpop"), mode: .hobby, bundle: en) == "Also into jpop")
        #expect(PeopleSuggestionText.reason(.similar, mode: .work, bundle: en) == "Similar background")
    }
}

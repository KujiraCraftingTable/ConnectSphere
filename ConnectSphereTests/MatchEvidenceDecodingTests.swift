import Foundation
import Testing
@testable import ConnectSphere

struct MatchEvidenceDecodingTests {
    private func decode(_ json: String) throws -> MatchEvidenceDTO {
        try JSONDecoder().decode(MatchEvidenceDTO.self, from: Data(json.utf8))
    }

    @Test func engagementEvidenceCarriesPublicReactionCounts() throws {
        let ev = try decode(#"{"type":"engagement","topic":"rock climbing","similarity":0.61,"matched_terms":["climbing"],"commented_count":2,"shared_count":1}"#)
        #expect(ev.type == "engagement")
        #expect(ev.commentedCount == 2)
        #expect(ev.sharedCount == 1)
    }

    @Test func authoredPostEvidenceHasNoReactionCounts() throws {
        let ev = try decode(#"{"type":"post","topic":"hiking","similarity":0.7,"matched_terms":[],"post_count":3}"#)
        #expect(ev.commentedCount == nil)
        #expect(ev.sharedCount == nil)
        #expect(ev.postCount == 3)
    }
}

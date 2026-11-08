import Foundation
import Testing
@testable import ConnectSphere

/// The official @connectsphere account (server migration 104): its badge and
/// the hidden Report/Block hang off `is_official`, which older servers and
/// deleted authors leave out.
struct OfficialAccountTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder.makeISO8601().decode(T.self, from: Data(json.utf8))
    }

    @Test func postAuthorCarriesTheFlag() throws {
        let official = try decode(PostAuthorDTO.self, """
            {"id":"a","username":"connectsphere","display_name":"ConnectSphere","avatar_color":"#1E88E5","is_official":true}
            """)
        #expect(official.isOfficial)
        #expect(official.toUserProfile().isOfficial)
    }

    @Test func missingFlagMeansNotOfficial() throws {
        let someone = try decode(PostAuthorDTO.self, """
            {"id":"b","username":"linh","display_name":"Linh","avatar_color":"#43A047"}
            """)
        #expect(!someone.isOfficial)
        #expect(!PostAuthorDTO.deleted.isOfficial)
        let commenter = try decode(CommentAuthorDTO.self, """
            {"id":"b","display_name":"Linh","avatar_color":"#43A047","is_official":null}
            """)
        #expect(!commenter.isOfficial)
    }

    @Test func adminStatsDecode() throws {
        let s = try decode(AdminStats.self, """
            {"accounts":58,"new_accounts_7d":2,"profiles":{"hobby":50,"work":40},"posts":{"hobby":151,"work":108},
             "posts_7d":{"hobby":3,"work":1},"open_cases":0,"pending_appeals":0,"reports_7d":0}
            """)
        #expect(s.posts.hobby == 151)
        #expect(s.posts.work == 108)
    }
}

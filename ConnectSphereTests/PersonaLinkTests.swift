import Foundation
import Testing
@testable import ConnectSphere

/// "See Work / Hobby profile": the persona's switch, and the other persona existing.
struct PersonaLinkTests {
    private func user(link: String = "", hobby: Bool = true, work: Bool = true) throws -> UserProfile {
        let json = """
        {"id":"u1","username":"kujira","display_name":"Kujira","avatar_color":"#123456",
         "follower_count":0,"following_count":0,"post_count":0,"interests":[],"skills":[],
         "hobby_setup":\(hobby),"work_setup":\(work)\(link)}
        """
        return try JSONDecoder.makeISO8601().decode(UserDTO.self, from: Data(json.utf8)).toUserProfile()
    }

    @Test func missingFlagMeansOn() throws {
        #expect(try user().linksOtherMode)
        #expect(try !user(link: #","links_other_mode":false"#).linksOtherMode)
    }

    @Test func buttonNeedsTheOtherPersona() throws {
        #expect(try user().otherModeLinked(from: .hobby))
        #expect(try !user(work: false).otherModeLinked(from: .hobby))   // no Work persona to show
        #expect(try user(work: false).otherModeLinked(from: .work))    // Work → their Hobby side
        #expect(try !user(link: #","links_other_mode":false"#).otherModeLinked(from: .hobby))
    }
}

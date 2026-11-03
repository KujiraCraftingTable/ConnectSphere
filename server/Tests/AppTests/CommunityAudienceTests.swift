@testable import App
import XCTest

final class CommunityAudienceTests: XCTestCase {
    /// Only these two reach the database; anything else is refused before it.
    func testOnlyPublicAndMembersAreAccepted() {
        XCTAssertEqual(PostStore.communityAudiences, ["public", "members"])
        XCTAssertFalse(PostStore.communityAudiences.contains("friends"))
        XCTAssertFalse(PostStore.communityAudiences.contains(""))
    }
}

import Vapor
import SQLKit

/// The two community helpers the post layer needs before the full communities
/// port in Phase 3 (`communityModel.isMember` / `incrementPostCount`).
enum CommunityMemberStore {
    struct Membership: Decodable { let role: String }

    static func membership(_ communityID: String, _ userID: String, on db: any SQLDatabase) async throws -> Membership? {
        try await db.raw("SELECT role FROM community_members WHERE community_id = \(uuid: communityID) AND user_id = \(uuid: userID)")
            .first(decoding: Membership.self)
    }

    static func incrementPostCount(_ communityID: String, _ delta: Int, on db: any SQLDatabase) async throws {
        try await db.raw("UPDATE communities SET post_count = post_count + \(bind: delta) WHERE id = \(uuid: communityID)").run()
    }
}

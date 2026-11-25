import Vapor
import SQLKit

/// One-way, per-mode follows (migration 035). Friendship and following are
/// independent: becoming friends starts a mutual follow, and friends may
/// unfollow each other and stay friends. Profile "followers"/"following"
/// counts and lists only include people who are NOT friends in that mode.
enum FollowStore {
    static let modes: Set<String> = ["hobby", "work"]

    // MARK: - SQL fragments
    /// SQL: is (a, b) an accepted friendship in `modeRef`? Both arguments and
    /// `modeRef` are SQL expressions. Column refs or an allowlisted literal.
    private static func areFriends(_ a: String, _ b: String, modeRef: String) -> String {
        """
        EXISTS (SELECT 1 FROM connections c WHERE c.status = 'accepted' AND c.mode = \(modeRef)
                AND ((c.requester_id = \(a) AND c.addressee_id = \(b))
                  OR (c.requester_id = \(b) AND c.addressee_id = \(a))))
        """
    }

    /// Column fragments for the profile query, scoped to `modeRef` (an
    /// allowlisted literal such as `'hobby'`). `userRef` is the profile's id column.
    static func countColumns(userRef: String, modeRef: String) -> String {
        """
        (SELECT COUNT(*)::int FROM follows f JOIN users fu ON fu.id = f.follower_id AND fu.deleted_at IS NULL
         WHERE f.followee_id = \(userRef) AND f.mode = \(modeRef)
           AND NOT \(areFriends("f.follower_id", userRef, modeRef: modeRef))) AS follower_count,
        (SELECT COUNT(*)::int FROM follows f JOIN users fu ON fu.id = f.followee_id AND fu.deleted_at IS NULL
         WHERE f.follower_id = \(userRef) AND f.mode = \(modeRef)
           AND NOT \(areFriends("f.followee_id", userRef, modeRef: modeRef))) AS following_count
        """
    }

    // MARK: - Following
    static func follow(_ follower: String, _ followee: String, mode: String, on db: any SQLDatabase) async throws {
        try await db.raw("""
            INSERT INTO follows (follower_id, followee_id, mode)
            VALUES (\(uuid: follower), \(uuid: followee), \(bind: mode))
            ON CONFLICT DO NOTHING
            """).run()
    }

    static func unfollow(_ follower: String, _ followee: String, mode: String, on db: any SQLDatabase) async throws {
        try await db.raw("""
            DELETE FROM follows
            WHERE follower_id = \(uuid: follower) AND followee_id = \(uuid: followee) AND mode = \(bind: mode)
            """).run()
    }

    static func isFollowing(_ follower: String, _ followee: String, mode: String, on db: any SQLDatabase) async throws -> Bool {
        struct One: Decodable { let one: Int }
        return try await db.raw("""
            SELECT 1 AS one FROM follows
            WHERE follower_id = \(uuid: follower) AND followee_id = \(uuid: followee) AND mode = \(bind: mode)
            """).first(decoding: One.self) != nil
    }

    /// Blocking ends every follow between the two, in every mode.
    static func removeBetween(_ a: String, _ b: String, on db: any SQLDatabase) async throws {
        try await db.raw("""
            DELETE FROM follows
            WHERE (follower_id = \(uuid: a) AND followee_id = \(uuid: b))
               OR (follower_id = \(uuid: b) AND followee_id = \(uuid: a))
            """).run()
    }

    // MARK: - Follower lists
    struct Person: Content {
        var id: String
        var username: String
        @NullCoded var display_name: String?
        @NullCoded var avatar_url: String?
        @NullCoded var avatar_color: String?
        @NullCoded var job_title: String?
        @NullCoded var company: String?
        @NullCoded var location: String?
    }

    /// Followers (`followers == true`) or followees of `userID` in `mode`,
    /// newest first, friends excluded. The same people the counts count.
    static func list(of userID: String, followers: Bool, mode: String, limit: Int, offset: Int,
                     on db: any SQLDatabase) async throws -> [Person] {
        let other = followers ? "f.follower_id" : "f.followee_id"
        let me = followers ? "f.followee_id" : "f.follower_id"
        let modeRef = "'\(mode)'"   // allowlisted by the caller
        return try await db.raw("""
            SELECT u.id::text AS id, u.username,
                   COALESCE(\(unsafeRaw: PersonaSQL.expr("display_name", modeRef: modeRef)), u.username) AS display_name,
                   \(unsafeRaw: PersonaSQL.expr("avatar_url", modeRef: modeRef)) AS avatar_url,
                   COALESCE(u.avatar_color, '#7F5AF0') AS avatar_color, u.job_title, u.company, u.location
            FROM follows f JOIN users u ON u.id = \(unsafeRaw: other) AND u.deleted_at IS NULL
            WHERE \(unsafeRaw: me) = \(uuid: userID) AND f.mode = \(unsafeRaw: modeRef)
              AND NOT \(unsafeRaw: areFriends(other, me, modeRef: modeRef))
            ORDER BY f.created_at DESC
            LIMIT \(bind: limit) OFFSET \(bind: offset)
            """).all(decoding: Person.self)
    }
}

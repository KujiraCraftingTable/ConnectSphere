import Vapor
import SQLKit

/// The seller's Marketplace identity and who follows them (migration 135).
///
/// Each field the seller left empty falls back to their normal persona, so a
/// seller who never set one still looks like themselves. Seller follows are
/// their own table: they never count as friends or follows.
enum SellerProfileStore {
    static let maxNameLength = 50
    static let maxBioLength = 300

    struct Profile: Content {
        var user_id: String
        var username: String
        /// What everyone sees: the marketplace value, else the persona's.
        var display_name: String
        @NullCoded var avatar_url: String?
        @NullCoded var cover_url: String?
        @NullCoded var bio: String?
        var avatar_color: String?
        /// Only what the seller set themselves (nil = uses their profile), so
        /// the edit screen can tell the two apart.
        @NullCoded var own_display_name: String?
        @NullCoded var own_avatar_url: String?
        @NullCoded var own_cover_url: String?
        @NullCoded var own_bio: String?
        /// The normal profile's photo and cover, so the edit screen can show
        /// what "use my profile's" falls back to.
        @NullCoded var profile_avatar_url: String?
        @NullCoded var profile_cover_url: String?
        var follower_count: Int
        var is_following: Bool
    }

    static func get(seller: String, mode: String, viewer: String, on db: any SQLDatabase) async throws -> Profile? {
        struct R: Decodable {
            let user_id: String; let username: String; let persona_name: String
            let persona_avatar: String?; let persona_cover: String?; let persona_bio: String?; let avatar_color: String?
            let own_name: String?; let own_avatar: String?; let own_cover: String?; let own_bio: String?
            let follower_count: Int; let is_following: Bool
        }
        // `mode` is hobby/work by now (checked in the controller), so it's a safe literal.
        let m = "'\(mode)'"
        guard let r = try await db.raw("""
            SELECT u.id::text AS user_id, u.username, u.avatar_color,
              \(unsafeRaw: PersonaSQL.expr("display_name", modeRef: m)) AS persona_name,
              \(unsafeRaw: PersonaSQL.expr("avatar_url", modeRef: m)) AS persona_avatar,
              \(unsafeRaw: PersonaSQL.expr("cover_url", modeRef: m)) AS persona_cover,
              \(unsafeRaw: PersonaSQL.expr("bio", modeRef: m)) AS persona_bio,
              sp.display_name AS own_name, sp.avatar_url AS own_avatar, sp.cover_url AS own_cover, sp.bio AS own_bio,
              (SELECT COUNT(*)::int FROM seller_follows f WHERE f.seller_id = u.id AND f.mode = \(bind: mode)) AS follower_count,
              EXISTS (SELECT 1 FROM seller_follows f WHERE f.seller_id = u.id AND f.mode = \(bind: mode)
                      AND f.follower_id = \(uuid: viewer)) AS is_following
            FROM users u
            LEFT JOIN seller_profiles sp ON sp.user_id = u.id AND sp.mode = \(bind: mode)
            WHERE u.id = \(uuid: seller) AND u.deleted_at IS NULL
            """).first(decoding: R.self) else { return nil }
        return Profile(user_id: r.user_id, username: r.username, display_name: r.own_name ?? r.persona_name,
                       avatar_url: r.own_avatar ?? r.persona_avatar, cover_url: r.own_cover ?? r.persona_cover,
                       bio: r.own_bio ?? r.persona_bio, avatar_color: r.avatar_color,
                       own_display_name: r.own_name, own_avatar_url: r.own_avatar, own_cover_url: r.own_cover,
                       own_bio: r.own_bio, profile_avatar_url: r.persona_avatar, profile_cover_url: r.persona_cover,
                       follower_count: r.follower_count, is_following: r.is_following)
    }

    /// The name followers see in a "listed" notification.
    static func displayName(of seller: String, mode: String, on db: any SQLDatabase) async throws -> String {
        try await get(seller: seller, mode: mode, viewer: seller, on: db)?.display_name ?? ""
    }

    struct Fields {
        var displayName: String?
        var avatarURL: String?
        var coverURL: String?
        var bio: String?
    }

    /// Replaces the seller's marketplace fields; nil clears one back to the
    /// profile's. Inputs are validated by the caller.
    static func save(seller: String, mode: String, _ f: Fields, on db: any SQLDatabase) async throws {
        try await db.raw("""
            INSERT INTO seller_profiles (user_id, mode, display_name, avatar_url, cover_url, bio)
            VALUES (\(uuid: seller), \(bind: mode), \(bind: f.displayName), \(bind: f.avatarURL), \(bind: f.coverURL), \(bind: f.bio))
            ON CONFLICT (user_id, mode) DO UPDATE SET
              display_name = EXCLUDED.display_name, avatar_url = EXCLUDED.avatar_url,
              cover_url = EXCLUDED.cover_url, bio = EXCLUDED.bio, updated_at = NOW()
            """).run()
    }

    static func follow(_ follower: String, seller: String, mode: String, on db: any SQLDatabase) async throws {
        try await db.raw("""
            INSERT INTO seller_follows (follower_id, seller_id, mode)
            VALUES (\(uuid: follower), \(uuid: seller), \(bind: mode)) ON CONFLICT DO NOTHING
            """).run()
    }

    static func unfollow(_ follower: String, seller: String, mode: String, on db: any SQLDatabase) async throws {
        try await db.raw("""
            DELETE FROM seller_follows
            WHERE follower_id = \(uuid: follower) AND seller_id = \(uuid: seller) AND mode = \(bind: mode)
            """).run()
    }

    /// Followers to tell about a new listing, minus anyone blocked either way.
    static func followers(of seller: String, mode: String, on db: any SQLDatabase) async throws -> [String] {
        struct R: Decodable { let id: String }
        return try await db.raw("""
            SELECT f.follower_id::text AS id FROM seller_follows f
            JOIN users u ON u.id = f.follower_id AND u.deleted_at IS NULL
            WHERE f.seller_id = \(uuid: seller) AND f.mode = \(bind: mode)
              AND NOT EXISTS (SELECT 1 FROM user_blocks b
                              WHERE (b.blocker_id = f.follower_id AND b.blocked_id = f.seller_id)
                                 OR (b.blocker_id = f.seller_id AND b.blocked_id = f.follower_id))
            """).all(decoding: R.self).map(\.id)
    }

    /// SQL for a listing post's author name/avatar: the seller's marketplace
    /// value when set. `post`/`fallback` are trusted SQL fragments.
    static func authorExpr(_ field: String, post: String, fallback: String) -> String {
        "COALESCE(CASE WHEN \(post).post_type IN ('listing', 'legit') THEN (SELECT spf.\(field) FROM seller_profiles spf WHERE spf.user_id = \(post).author_id AND spf.mode = \(post).mode) END, \(fallback))"
    }
}

import Vapor
import SQLKit

/// Dating (migration 081): one opt-in profile per account, likes and passes,
/// and matches that chat in the Hobby inbox. The browse query applies
/// `DatingRules` in SQL; the age band is re-checked on every read and write,
/// so someone who turns out to be in the other band is never shown.
enum DatingStore {
    // MARK: SQL fragments

    /// Profile + account of the signed-in user, as CTE `me`. `browse`,
    /// `likesYou` and `matches` need one row here, so callers check that a
    /// profile exists first.
    private static func meCTE(_ me: String) -> SQLQueryString {
        """
        me AS (
          SELECT p.*, u.age, u.gender FROM dating_profiles p JOIN users u ON u.id = p.user_id
          WHERE p.user_id = \(uuid: me)
        )
        """
    }

    /// km between profile `p` and `me` — the formula of `DatingRules.distanceKm`.
    private static let distanceSQL = """
        (2 * 6371 * asin(least(1, sqrt(
            power(sin(radians(p.latitude - me.latitude) / 2), 2)
          + cos(radians(me.latitude)) * cos(radians(p.latitude))
          * power(sin(radians(p.longitude - me.longitude) / 2), 2)))))
        """

    /// Account `u` (with profile `p`) is someone `me` may deal with at all:
    /// an active, undeleted 16+ profile in the same age band, with no block
    /// either way. Preferences are left to `browse`. A match stays listed
    /// while the other person's profile is on a break (`requireActive: false`).
    private static func reachableSQL(requireActive: Bool = true) -> String {
        """
        \(requireActive ? "p.is_active AND " : "")u.deleted_at IS NULL AND u.hobby_deleted_at IS NULL
        AND u.age >= \(DatingRules.minAge) AND me.age >= \(DatingRules.minAge)
        AND (u.age >= \(DatingRules.adultAge)) = (me.age >= \(DatingRules.adultAge))
        AND NOT EXISTS (SELECT 1 FROM user_blocks b
                        WHERE (b.blocker_id = me.user_id AND b.blocked_id = u.id)
                           OR (b.blocker_id = u.id AND b.blocked_id = me.user_id))
        """
    }

    /// Account `u` isn't one of my Hobby friends: like Facebook Dating, people
    /// you're already connected with are never suggested to each other.
    private static let notFriendsSQL = """
        NOT EXISTS (SELECT 1 FROM connections cn
                    WHERE cn.mode = 'hobby' AND cn.status = 'accepted'
                      AND ((cn.requester_id = me.user_id AND cn.addressee_id = u.id)
                        OR (cn.requester_id = u.id AND cn.addressee_id = me.user_id)))
        """

    private static func wantsSQL(_ interestedIn: String, _ gender: String) -> String {
        "(\(interestedIn) = 'everyone' OR (\(interestedIn) = 'men' AND \(gender) = 'male') OR (\(interestedIn) = 'women' AND \(gender) = 'female'))"
    }

    /// A person's card, for profile `p` / account `u` seen by `me`. Dating
    /// shows the Hobby name only — never the username, so a card can't be
    /// looked up elsewhere in the app.
    private static let cardColumns = """
        u.id::text AS id,
        \(PersonaSQL.expr("display_name", modeRef: "'hobby'")) AS display_name,
        u.avatar_color, u.age, p.city, p.bio, p.height_cm, p.has_kids,
        round(\(distanceSQL))::int AS distance_km,
        ARRAY(SELECT ph.url FROM dating_photos ph WHERE ph.user_id = u.id ORDER BY ph.position) AS photos,
        ARRAY(SELECT i.interest FROM user_interests i
              WHERE i.user_id = u.id AND lower(i.interest) IN
                (SELECT lower(mi.interest) FROM user_interests mi WHERE mi.user_id = me.user_id)
              ORDER BY i.interest) AS shared_interests
        """

    struct Card: Content {
        var id: String
        var display_name: String
        @NullCoded var avatar_color: String?
        var age: Int
        var city: String
        var bio: String
        @NullCoded var height_cm: Int?
        @NullCoded var has_kids: String?
        var distance_km: Int
        var photos: [String]
        var shared_interests: [String]
    }

    // MARK: access

    struct Account: Decodable { let age: Int?; let gender: String }

    static func account(_ me: String, on db: any SQLDatabase) async throws -> Account? {
        try await db.raw("SELECT age, gender FROM users WHERE id = \(uuid: me) AND deleted_at IS NULL")
            .first(decoding: Account.self)
    }

    // MARK: own profile

    struct Profile: Content {
        var bio: String
        var interested_in: String
        var min_age: Int
        var max_age: Int
        @NullCoded var max_distance_km: Int?
        @NullCoded var height_cm: Int?
        @NullCoded var has_kids: String?
        var city: String
        var latitude: Double
        var longitude: Double
        var is_active: Bool
        var photos: [String]
    }

    static func profile(_ me: String, on db: any SQLDatabase) async throws -> Profile? {
        try await db.raw("""
            SELECT bio, interested_in, min_age, max_age, max_distance_km, height_cm, has_kids, city, latitude, longitude, is_active,
              ARRAY(SELECT url FROM dating_photos WHERE user_id = p.user_id ORDER BY position) AS photos
            FROM dating_profiles p WHERE user_id = \(uuid: me)
            """).first(decoding: Profile.self)
    }

    /// Saves the whole profile, photos in the given order. Saving turns the
    /// profile back on.
    static func save(_ me: String, _ p: DatingRules.ProfileInput, on db: AppDatabase) async throws {
        try await db.tx { t in
            try await t.raw("""
                INSERT INTO dating_profiles
                  (user_id, bio, interested_in, min_age, max_age, max_distance_km, height_cm, has_kids, city, latitude, longitude)
                VALUES (\(uuid: me), \(bind: p.bio), \(bind: p.interestedIn), \(bind: p.minAge), \(bind: p.maxAge),
                        \(bind: p.maxDistanceKm), \(bind: p.heightCm), \(bind: p.hasKids), \(bind: p.city),
                        \(bind: p.latitude), \(bind: p.longitude))
                ON CONFLICT (user_id) DO UPDATE SET
                  bio = EXCLUDED.bio, interested_in = EXCLUDED.interested_in,
                  min_age = EXCLUDED.min_age, max_age = EXCLUDED.max_age,
                  max_distance_km = EXCLUDED.max_distance_km, height_cm = EXCLUDED.height_cm,
                  has_kids = EXCLUDED.has_kids,
                  city = EXCLUDED.city, latitude = EXCLUDED.latitude, longitude = EXCLUDED.longitude,
                  location_updated_at = NOW(), is_active = TRUE, updated_at = NOW()
                """).run()
            try await t.raw("DELETE FROM dating_photos WHERE user_id = \(uuid: me)").run()
            for (i, url) in p.photos.enumerated() {
                try await t.raw("INSERT INTO dating_photos (user_id, position, url) VALUES (\(uuid: me), \(bind: i), \(bind: url))").run()
            }
        }
    }

    @discardableResult
    static func setActive(_ me: String, _ active: Bool, on db: any SQLDatabase) async throws -> Bool {
        struct R: Decodable { let user_id: String }
        return try await db.raw("""
            UPDATE dating_profiles SET is_active = \(bind: active), updated_at = NOW()
            WHERE user_id = \(uuid: me) RETURNING user_id::text AS user_id
            """).first(decoding: R.self) != nil
    }

    /// The phone's latest position (the app sends it each time Dating opens).
    @discardableResult
    static func updateLocation(_ me: String, city: String, latitude: Double, longitude: Double,
                               on db: any SQLDatabase) async throws -> Bool {
        struct R: Decodable { let user_id: String }
        return try await db.raw("""
            UPDATE dating_profiles SET city = \(bind: city), latitude = \(bind: latitude), longitude = \(bind: longitude),
              location_updated_at = NOW(), updated_at = NOW()
            WHERE user_id = \(uuid: me) RETURNING user_id::text AS user_id
            """).first(decoding: R.self) != nil
    }

    /// What the setup's "Your basics" step shows: the Hobby name, age and
    /// gender, which come from the account and are changed there.
    struct Basics: Content {
        var display_name: String
        @NullCoded var age: Int?
        var gender: String
    }

    static func basics(_ me: String, on db: any SQLDatabase) async throws -> Basics? {
        try await db.raw("""
            SELECT \(unsafeRaw: PersonaSQL.expr("display_name", modeRef: "'hobby'")) AS display_name, u.age, u.gender
            FROM users u WHERE u.id = \(uuid: me)
            """).first(decoding: Basics.self)
    }

    /// Deletes the profile with every like, pass and match, as if Dating had
    /// never been used. Chats a match opened go too; older Hobby chats stay.
    static func deleteProfile(_ me: String, on db: AppDatabase) async throws {
        try await db.tx { t in
            struct M: Decodable { let id: String }
            let ids = try await t.raw("""
                SELECT id::text AS id FROM dating_matches WHERE user_a = \(uuid: me) OR user_b = \(uuid: me)
                """).all(decoding: M.self)
            for m in ids { try await endMatch(m.id, on: t) }
            try await t.raw("DELETE FROM dating_likes WHERE from_user = \(uuid: me) OR to_user = \(uuid: me)").run()
            try await t.raw("DELETE FROM dating_profiles WHERE user_id = \(uuid: me)").run()
        }
    }

    // MARK: browse

    static let browseLimit = 20

    /// People to like or pass: everyone who fits both ways (see
    /// `DatingRules.isFit`), minus those already answered and those who passed
    /// on me. Shared Hobby interests first, then closeness of the Hobby
    /// profile embeddings, then distance.
    static func browse(_ me: String, on db: any SQLDatabase) async throws -> [Card] {
        try await db.raw("""
            WITH \(meCTE(me)),
            my_vec AS (
              SELECT embedding FROM user_embedding_chunks
              WHERE user_id = \(uuid: me) AND source_type = 'user_profile' AND chunk_index = 0
            ),
            cards AS (
              SELECT \(unsafeRaw: cardColumns),
                \(unsafeRaw: distanceSQL) AS km, p.max_distance_km AS their_limit, me.max_distance_km AS my_limit,
                (SELECT (1 - (ch.embedding <=> my_vec.embedding))::float FROM user_embedding_chunks ch, my_vec
                  WHERE ch.user_id = u.id AND ch.source_type = 'user_profile' AND ch.chunk_index = 0) AS similarity
              FROM dating_profiles p JOIN users u ON u.id = p.user_id, me
              WHERE p.user_id <> me.user_id AND \(unsafeRaw: reachableSQL()) AND \(unsafeRaw: notFriendsSQL)
                AND u.age BETWEEN me.min_age AND me.max_age
                AND me.age BETWEEN p.min_age AND p.max_age
                AND \(unsafeRaw: wantsSQL("me.interested_in", "u.gender"))
                AND \(unsafeRaw: wantsSQL("p.interested_in", "me.gender"))
                AND NOT EXISTS (SELECT 1 FROM dating_likes l WHERE l.from_user = me.user_id AND l.to_user = u.id)
                AND NOT EXISTS (SELECT 1 FROM dating_likes l WHERE l.from_user = u.id AND l.to_user = me.user_id AND NOT l.liked)
            )
            SELECT id, display_name, avatar_color, age, city, bio, height_cm, has_kids, distance_km, photos, shared_interests
            FROM cards
            WHERE km <= COALESCE(my_limit, 1e9) AND km <= COALESCE(their_limit, 1e9)
            ORDER BY cardinality(shared_interests) DESC, similarity DESC NULLS LAST, km ASC
            LIMIT \(unsafeRaw: String(browseLimit))
            """).all(decoding: Card.self)
    }

    // MARK: likes you

    struct Liker: Content { var card: Card; var liked_at: Date }

    /// People who liked me and whom I haven't answered yet, newest first. My
    /// own age and distance choices don't hide them — they already chose me.
    static func likesYou(_ me: String, on db: any SQLDatabase) async throws -> [Liker] {
        struct When: Decodable { let liked_at: Date }
        let rows = try await db.raw("""
            WITH \(meCTE(me))
            SELECT \(unsafeRaw: cardColumns), l.created_at AS liked_at
            FROM dating_likes l
            JOIN dating_profiles p ON p.user_id = l.from_user
            JOIN users u ON u.id = p.user_id, me
            WHERE l.to_user = me.user_id AND l.liked AND \(unsafeRaw: reachableSQL()) AND \(unsafeRaw: notFriendsSQL)
              AND NOT EXISTS (SELECT 1 FROM dating_likes r WHERE r.from_user = me.user_id AND r.to_user = u.id)
            ORDER BY l.created_at DESC
            LIMIT 100
            """).all()
        return try rows.map { Liker(card: try $0.decode(model: Card.self), liked_at: try $0.decode(model: When.self).liked_at) }
    }

    // MARK: like / pass

    struct LikeResult: Content {
        var matched: Bool
        @NullCoded var match_id: String?
        @NullCoded var conversation_id: String?
        /// The match is new with this like — the moment to celebrate it.
        var is_new: Bool
    }

    /// Whether `target` is someone `me` may like: see `reachableSQL`.
    static func canReach(_ me: String, _ target: String, on db: any SQLDatabase) async throws -> Bool {
        struct R: Decodable { let id: String }
        return try await db.raw("""
            WITH \(meCTE(me))
            SELECT u.id::text AS id FROM dating_profiles p JOIN users u ON u.id = p.user_id, me
            WHERE p.user_id = \(uuid: target) AND p.user_id <> me.user_id AND \(unsafeRaw: reachableSQL())
            """).first(decoding: R.self) != nil
    }

    /// Records a like or a pass. A like back from someone who already liked me
    /// makes the match and its chat in the same transaction, under a lock on
    /// the pair, so two people liking each other at once can't both miss it.
    static func respond(_ me: String, to target: String, liked: Bool, on db: AppDatabase) async throws -> LikeResult {
        let pair = DatingRules.pair(me, target)
        return try await db.withTransaction { t in
            try await t.raw("SELECT pg_advisory_xact_lock(hashtext(\(bind: "dating:" + pair.a + pair.b)))").run()
            if let existing = try await match(pair, on: t) {
                return LikeResult(matched: true, match_id: existing.id, conversation_id: existing.conversation_id, is_new: false)
            }
            try await t.raw("""
                INSERT INTO dating_likes (from_user, to_user, liked) VALUES (\(uuid: me), \(uuid: target), \(bind: liked))
                ON CONFLICT (from_user, to_user) DO UPDATE SET liked = EXCLUDED.liked, created_at = NOW()
                """).run()
            struct L: Decodable { let liked: Bool }
            let theyLikedMe = try await t.raw("""
                SELECT liked FROM dating_likes WHERE from_user = \(uuid: target) AND to_user = \(uuid: me)
                """).first(decoding: L.self)?.liked ?? false
            guard DatingRules.makesMatch(liked: liked, theyLikedMe: theyLikedMe) else {
                return LikeResult(matched: false, match_id: nil, conversation_id: nil, is_new: false)
            }
            let made = try await makeMatch(pair, on: t)
            return LikeResult(matched: true, match_id: made.id, conversation_id: made.conversation_id, is_new: true)
        }
    }

    private struct MatchRow: Decodable { let id: String; let conversation_id: String? }

    private static func match(_ pair: (a: String, b: String), on db: any SQLDatabase) async throws -> MatchRow? {
        try await db.raw("""
            SELECT id::text AS id, conversation_id::text AS conversation_id FROM dating_matches
            WHERE user_a = \(uuid: pair.a) AND user_b = \(uuid: pair.b)
            """).first(decoding: MatchRow.self)
    }

    /// The match chats in the pair's existing Hobby 1:1 if they have one
    /// (accepting it if it was still a message request), else in a new one.
    private static func makeMatch(_ pair: (a: String, b: String), on t: any SQLDatabase) async throws -> MatchRow {
        struct I: Decodable { let id: String }
        let matchID = try await t.raw("""
            INSERT INTO dating_matches (user_a, user_b) VALUES (\(uuid: pair.a), \(uuid: pair.b))
            RETURNING id::text AS id
            """).first(decoding: I.self)!.id
        var conversationID = try await ChatStore.findConversation(pair.a, pair.b, mode: "hobby", on: t)
        let created = conversationID == nil
        if let existing = conversationID {
            try await t.raw("""
                UPDATE conversations SET dating_match_id = \(uuid: matchID),
                  request_accepted_at = CASE WHEN request_from IS NOT NULL THEN COALESCE(request_accepted_at, NOW()) ELSE request_accepted_at END
                WHERE id = \(uuid: existing)
                """).run()
        } else {
            let id = try await t.raw("""
                INSERT INTO conversations (mode, dating_match_id) VALUES ('hobby', \(uuid: matchID)) RETURNING id::text AS id
                """).first(decoding: I.self)!.id
            try await t.raw("""
                INSERT INTO conversation_participants (conversation_id, user_id) VALUES (\(uuid: id), \(uuid: pair.a)), (\(uuid: id), \(uuid: pair.b))
                """).run()
            conversationID = id
        }
        try await t.raw("""
            UPDATE dating_matches SET conversation_id = \(uuid: conversationID), created_conversation = \(bind: created)
            WHERE id = \(uuid: matchID)
            """).run()
        return MatchRow(id: matchID, conversation_id: conversationID)
    }

    // MARK: matches

    struct Match: Content {
        var id: String
        @NullCoded var conversation_id: String?
        var matched_at: Date
        var person: Card
    }

    static func matches(_ me: String, on db: any SQLDatabase) async throws -> [Match] {
        struct Head: Decodable { let match_id: String; let conversation_id: String?; let matched_at: Date }
        let rows = try await db.raw("""
            WITH \(meCTE(me))
            SELECT m.id::text AS match_id, m.conversation_id::text AS conversation_id, m.created_at AS matched_at,
              \(unsafeRaw: cardColumns)
            FROM me
            JOIN dating_matches m ON m.user_a = me.user_id OR m.user_b = me.user_id
            JOIN dating_profiles p ON p.user_id = CASE WHEN m.user_a = me.user_id THEN m.user_b ELSE m.user_a END
            JOIN users u ON u.id = p.user_id
            WHERE \(unsafeRaw: reachableSQL(requireActive: false))
            ORDER BY m.created_at DESC
            """).all()
        return try rows.map {
            let head = try $0.decode(model: Head.self)
            return Match(id: head.match_id, conversation_id: head.conversation_id, matched_at: head.matched_at,
                         person: try $0.decode(model: Card.self))
        }
    }

    /// Ends one of my matches. Both people become passes for each other, so
    /// neither is shown to the other again.
    static func unmatch(_ me: String, matchID: String, on db: AppDatabase) async throws -> Bool {
        try await db.withTransaction { t in
            struct R: Decodable { let id: String }
            guard try await t.raw("""
                SELECT id::text AS id FROM dating_matches
                WHERE id = \(uuid: matchID) AND (user_a = \(uuid: me) OR user_b = \(uuid: me)) FOR UPDATE
                """).first(decoding: R.self) != nil else { return false }
            try await endMatch(matchID, on: t)
            return true
        }
    }

    /// Removes a match: its own chat is deleted, an older Hobby chat just
    /// loses the Dating mark; both directions are recorded as passes.
    private static func endMatch(_ matchID: String, on t: any SQLDatabase) async throws {
        struct R: Decodable { let user_a: String; let user_b: String; let conversation_id: String?; let created_conversation: Bool }
        guard let m = try await t.raw("""
            SELECT user_a::text AS user_a, user_b::text AS user_b, conversation_id::text AS conversation_id, created_conversation
            FROM dating_matches WHERE id = \(uuid: matchID)
            """).first(decoding: R.self) else { return }
        if let cid = m.conversation_id {
            if m.created_conversation {
                try await t.raw("DELETE FROM conversations WHERE id = \(uuid: cid)").run()
            } else {
                try await t.raw("UPDATE conversations SET dating_match_id = NULL WHERE id = \(uuid: cid)").run()
            }
        }
        try await t.raw("""
            INSERT INTO dating_likes (from_user, to_user, liked)
            VALUES (\(uuid: m.user_a), \(uuid: m.user_b), FALSE), (\(uuid: m.user_b), \(uuid: m.user_a), FALSE)
            ON CONFLICT (from_user, to_user) DO UPDATE SET liked = FALSE, created_at = NOW()
            """).run()
        try await t.raw("DELETE FROM dating_matches WHERE id = \(uuid: matchID)").run()
    }
}

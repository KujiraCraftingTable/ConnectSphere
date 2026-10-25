import Vapor
import SQLKit

/// Port of `backend/src/models/communityModel.js` + `joinRequestModel.js`.
/// Review fixes folded in: `joinCommunity` uses `ON CONFLICT DO NOTHING
/// RETURNING`, `incrementMemberCount` has a 0 floor, `reviewRequest` is
/// status-guarded.
enum CommunityStore {

    /// `getCommunityById` — always includes `created_by`, `is_member`, `role`
    /// (null when not a member) and `join_request_status` (null when none).
    struct CommunityDetail: Content {
        var id: String
        @NullCoded var description: String?
        var name: String
        var type: String
        var privacy: String
        var icon_emoji: String
        @NullCoded var avatar_url: String?
        /// The community's picture (migration 070) — no profile picture any more.
        @NullCoded var cover_url: String?
        var cover_color: String
        var member_count: Int
        var post_count: Int
        var created_at: Date
        @NullCoded var name_changed_at: Date?
        var require_post_approval: Bool
        var created_by: String
        var is_member: Bool
        @NullCoded var role: String?
        @NullCoded var join_request_status: String?
        /// Feed-visibility mute — false for a non-member (nothing to mute).
        var is_muted: Bool
        var is_pinned: Bool
        /// all | friends | off — null for a non-member.
        @NullCoded var notify_level: String?
    }

    /// List endpoints (`search`, `/me`, `recommendations`, `trending`,
    /// `discover`). `is_member` + `trending_score` are present for search and
    /// absent for `/me`; `role` is always emitted (null when not a member).
    struct CommunityRow: Content {
        var id: String
        @NullCoded var description: String?
        var name: String
        var type: String
        var privacy: String
        var icon_emoji: String
        @NullCoded var avatar_url: String?
        @NullCoded var cover_url: String?
        var cover_color: String
        var member_count: Int
        var post_count: Int
        var created_at: Date
        @NullCoded var role: String?
        var is_member: Bool
        var trending_score: Double
        /// Pinned to the top of the viewer's own list.
        var is_pinned: Bool
    }

    /// The columns every list row shares (`c` = communities).
    static let rowColumns: SQLQueryString = """
        c.id::text AS id, c.name, c.description, c.type, c.privacy, c.icon_emoji, c.avatar_url, c.cover_url,
        c.cover_color, c.member_count, c.post_count, c.created_at
        """

    static func byID(_ id: String, viewer: String?, on db: any SQLDatabase) async throws -> CommunityDetail? {
        let q: SQLQueryString
        if let viewer {
            q = """
                SELECT c.id::text AS id, c.name, c.description, c.type, c.privacy, c.icon_emoji, c.avatar_url, c.cover_url, c.cover_color,
                  c.member_count, c.post_count, c.created_by::text AS created_by, c.created_at, c.name_changed_at,
                  c.require_post_approval,
                  (cm.user_id IS NOT NULL) AS is_member, cm.role, jr.status AS join_request_status,
                  COALESCE(cm.muted, false) AS is_muted, (cm.pinned_at IS NOT NULL) AS is_pinned, cm.notify_level
                FROM communities c
                LEFT JOIN community_members cm ON cm.community_id = c.id AND cm.user_id = \(uuid: viewer)
                LEFT JOIN community_join_requests jr ON jr.community_id = c.id AND jr.user_id = \(uuid: viewer)
                WHERE c.id = \(uuid: id)
                """
        } else {
            q = """
                SELECT c.id::text AS id, c.name, c.description, c.type, c.privacy, c.icon_emoji, c.avatar_url, c.cover_url, c.cover_color,
                  c.member_count, c.post_count, c.created_by::text AS created_by, c.created_at, c.name_changed_at,
                  c.require_post_approval,
                  false AS is_member, NULL::VARCHAR AS role, NULL::VARCHAR AS join_request_status,
                  false AS is_muted, false AS is_pinned, NULL::VARCHAR AS notify_level
                FROM communities c WHERE c.id = \(uuid: id)
                """
        }
        return try await db.raw(q).first(decoding: CommunityDetail.self)
    }

    static func countAdmins(_ communityID: String, on db: any SQLDatabase) async throws -> Int {
        struct N: Decodable { let n: Int }
        return try await db.raw("SELECT COUNT(*)::int AS n FROM community_members WHERE community_id = \(uuid: communityID) AND role = 'admin'")
            .first(decoding: N.self)?.n ?? 0
    }

    static func membership(_ communityID: String, _ userID: String, on db: any SQLDatabase) async throws -> String? {
        struct R: Decodable { let role: String }
        return try await db.raw("SELECT role FROM community_members WHERE community_id = \(uuid: communityID) AND user_id = \(uuid: userID)")
            .first(decoding: R.self)?.role
    }

    static func isBanned(_ communityID: String, _ userID: String, on db: any SQLDatabase) async throws -> Bool {
        struct One: Decodable { let one: Int }
        return try await db.raw("SELECT 1 AS one FROM community_bans WHERE community_id = \(uuid: communityID) AND user_id = \(uuid: userID)")
            .first(decoding: One.self) != nil
    }

    static func incrementMemberCount(_ communityID: String, _ delta: Int, on db: any SQLDatabase) async throws {
        // Review fix: never negative.
        try await db.raw("UPDATE communities SET member_count = GREATEST(member_count + \(bind: delta), 0) WHERE id = \(uuid: communityID)").run()
    }

    static func incrementPostCount(_ communityID: String, _ delta: Int, on db: any SQLDatabase) async throws {
        try await db.raw("UPDATE communities SET post_count = GREATEST(post_count + \(bind: delta), 0) WHERE id = \(uuid: communityID)").run()
    }

    /// Review fix: ON CONFLICT DO NOTHING; caller bumps the counter only when a
    /// row is actually inserted.
    @discardableResult
    static func joinCommunity(_ communityID: String, _ userID: String, role: String = "member", on db: any SQLDatabase) async throws -> Bool {
        struct R: Decodable { let user_id: String }
        let inserted = try await db.raw("""
            INSERT INTO community_members (community_id, user_id, role)
            VALUES (\(uuid: communityID), \(uuid: userID), \(bind: role))
            ON CONFLICT (community_id, user_id) DO NOTHING
            RETURNING user_id::text AS user_id
            """).first(decoding: R.self)
        return inserted != nil
    }

    static func leaveCommunity(_ communityID: String, _ userID: String, on db: any SQLDatabase) async throws -> Bool {
        struct R: Decodable { let user_id: String }
        return try await db.raw("DELETE FROM community_members WHERE community_id = \(uuid: communityID) AND user_id = \(uuid: userID) RETURNING user_id::text AS user_id")
            .first(decoding: R.self) != nil
    }

    static func setMuted(_ communityID: String, _ userID: String, _ muted: Bool, on db: any SQLDatabase) async throws {
        try await db.raw("UPDATE community_members SET muted = \(bind: muted) WHERE community_id = \(uuid: communityID) AND user_id = \(uuid: userID)").run()
    }

    static func setPinned(_ communityID: String, _ userID: String, _ pinned: Bool, on db: any SQLDatabase) async throws {
        try await db.raw("""
            UPDATE community_members SET pinned_at = CASE WHEN \(bind: pinned) THEN COALESCE(pinned_at, NOW()) END
            WHERE community_id = \(uuid: communityID) AND user_id = \(uuid: userID)
            """).run()
    }

    /// False when this person already reported it.
    static func reportCommunity(_ communityID: String, by reporter: String, reason: String, detail: String?,
                                on db: any SQLDatabase) async throws -> Bool {
        struct R: Decodable { let id: String }
        return try await db.raw("""
            INSERT INTO community_reports (reporter_id, target_type, target_id, community_id, reason, detail)
            VALUES (\(uuid: reporter), 'community', \(uuid: communityID), \(uuid: communityID), \(bind: reason), \(bind: detail))
            ON CONFLICT DO NOTHING RETURNING id::text AS id
            """).first(decoding: R.self) != nil
    }

    // MARK: notifications

    static func setNotifyLevel(_ communityID: String, _ userID: String, _ level: String, on db: any SQLDatabase) async throws {
        try await db.raw("""
            UPDATE community_members SET notify_level = \(bind: level)
            WHERE community_id = \(uuid: communityID) AND user_id = \(uuid: userID)
            """).run()
    }

    /// Who hears about a new post: members on "all posts", plus those on
    /// "friends' posts" who are connected to the author in the community's mode.
    static func newPostRecipients(_ communityID: String, author: String, on db: any SQLDatabase) async throws -> [String] {
        struct R: Decodable { let user_id: String }
        return try await db.raw("""
            SELECT m.user_id::text AS user_id
            FROM community_members m JOIN communities c ON c.id = m.community_id
            WHERE m.community_id = \(uuid: communityID) AND m.user_id <> \(uuid: author)
              AND (m.notify_level = 'all'
                OR (m.notify_level = 'friends' AND EXISTS (
                      SELECT 1 FROM connections k
                      WHERE k.status = 'accepted' AND k.mode = CASE WHEN c.type = 'work' THEN 'work' ELSE 'hobby' END
                        AND ((k.requester_id = m.user_id AND k.addressee_id = \(uuid: author))
                          OR (k.addressee_id = m.user_id AND k.requester_id = \(uuid: author))))))
            """).all(decoding: R.self).map(\.user_id)
    }

    // MARK: post approval

    /// A member's live post here waits for a moderator: approval is on and
    /// they aren't an admin or moderator.
    static func needsApproval(_ communityID: String, author: String, on db: any SQLDatabase) async throws -> Bool {
        struct R: Decodable { let needs: Bool }
        return try await db.raw("""
            SELECT (c.require_post_approval AND COALESCE(m.role, 'member') NOT IN ('admin', 'moderator')) AS needs
            FROM communities c
            LEFT JOIN community_members m ON m.community_id = c.id AND m.user_id = \(uuid: author)
            WHERE c.id = \(uuid: communityID)
            """).first(decoding: R.self)?.needs ?? false
    }

    static func pendingPosts(_ communityID: String, viewer: String, on db: any SQLDatabase) async throws -> [PostObject] {
        try await db.raw(PostStore.buildPostSelect(viewer)
            + " WHERE p.community_id = \(uuid: communityID) AND p.status = 'pending'"
            + " GROUP BY p.id, u.id ORDER BY p.created_at").all(decoding: PostStore.PostRow.self).map(PostStore.map)
    }

    struct Reviewed: Decodable { let author_id: String }

    /// nil when it isn't a pending post of this community. Approving dates
    /// it now, so it reaches feeds as new.
    static func review(_ postID: String, in communityID: String, approve: Bool, reason: String?, reviewer: String,
                       on db: any SQLDatabase) async throws -> Reviewed? {
        try await db.raw("""
            UPDATE posts SET
              status = \(unsafeRaw: approve ? "'posted'" : "'declined'")::post_status,
              created_at = CASE WHEN \(bind: approve) THEN NOW() ELSE created_at END,
              decline_reason = CASE WHEN \(bind: approve) THEN NULL ELSE \(bind: reason) END,
              reviewed_by = \(uuid: reviewer), reviewed_at = NOW()
            WHERE id = \(uuid: postID) AND community_id = \(uuid: communityID) AND status = 'pending'
            RETURNING author_id::text AS author_id
            """).first(decoding: Reviewed.self)
    }

    // MARK: manage your content

    struct MyComment: Content {
        var id: String
        var content: String
        @NullCoded var image_url: String?
        var created_at: Date
        var post_id: String
        /// The start of the post it's under.
        var post_excerpt: String
    }

    struct MyContentCounts: Content {
        var published: Int
        var pending: Int
        var declined: Int
        var comments: Int
    }

    struct MyContent: Content {
        var counts: MyContentCounts
        var posts: [PostObject]
        var comments: [MyComment]
    }

    static func myContent(_ communityID: String, viewer: String, kind: String, newestFirst: Bool, status: String,
                          limit: Int, offset: Int, on db: any SQLDatabase) async throws -> MyContent {
        let counts = try await db.raw("""
            SELECT
              COUNT(*) FILTER (WHERE p.status = 'posted')::int AS published,
              COUNT(*) FILTER (WHERE p.status = 'pending')::int AS pending,
              COUNT(*) FILTER (WHERE p.status = 'declined')::int AS declined,
              (SELECT COUNT(*)::int FROM comments c JOIN posts cp ON cp.id = c.post_id
                 WHERE cp.community_id = \(uuid: communityID) AND c.author_id = \(uuid: viewer)
                   AND c.deleted_at IS NULL AND c.status = 'posted' AND cp.status = 'posted') AS comments
            FROM posts p WHERE p.community_id = \(uuid: communityID) AND p.author_id = \(uuid: viewer)
            """).first(decoding: MyContentCounts.self) ?? MyContentCounts(published: 0, pending: 0, declined: 0, comments: 0)
        let direction: SQLQueryString = newestFirst ? " DESC" : " ASC"
        if kind == "comments" {
            let comments = try await db.raw("""
                SELECT c.id::text AS id, c.content, c.image_url, c.created_at, cp.id::text AS post_id,
                  LEFT(COALESCE(cp.content, ''), 80) AS post_excerpt
                FROM comments c JOIN posts cp ON cp.id = c.post_id
                WHERE cp.community_id = \(uuid: communityID) AND c.author_id = \(uuid: viewer)
                  AND c.deleted_at IS NULL AND c.status = 'posted' AND cp.status = 'posted'
                ORDER BY c.created_at
                """ + direction + " LIMIT \(bind: limit) OFFSET \(bind: offset)").all(decoding: MyComment.self)
            return MyContent(counts: counts, posts: [], comments: comments)
        }
        let statuses: SQLQueryString
        switch status {
        case "published": statuses = "('posted')"
        case "pending": statuses = "('pending')"
        case "declined": statuses = "('declined')"
        default: statuses = "('posted', 'pending', 'declined')"
        }
        let posts = try await db.raw(PostStore.buildPostSelect(viewer)
            + " WHERE p.community_id = \(uuid: communityID) AND p.author_id = \(uuid: viewer) AND p.status::text IN " + statuses
            + " GROUP BY p.id, u.id ORDER BY p.created_at" + direction
            + " LIMIT \(bind: limit) OFFSET \(bind: offset)").all(decoding: PostStore.PostRow.self).map(PostStore.map)
        return MyContent(counts: counts, posts: posts, comments: [])
    }

    // MARK: info page

    struct InfoPerson: Content {
        var id: String
        var display_name: String
        @NullCoded var avatar_url: String?
        @NullCoded var avatar_color: String?
        @NullCoded var role: String?
    }

    struct CommunityInfo: Content {
        @NullCoded var about: String?
        var privacy: String
        var created_at: Date
        @NullCoded var name_changed_at: Date?
        var member_count: Int
        /// The viewer's connections (in the community's mode) who joined — a few, and how many.
        var friends: [InfoPerson]
        var friends_count: Int
        /// Admins first, then moderators.
        var staff: [InfoPerson]
        var posts_today: Int
        var posts_week: Int
        var new_members_week: Int
    }

    static func info(_ id: String, viewer: String, on db: any SQLDatabase) async throws -> CommunityInfo? {
        guard let c = try await byID(id, viewer: viewer, on: db) else { return nil }
        // Each person as they appear in this community's mode; a fixed literal.
        let mode = c.type == "work" ? "'work'" : "'hobby'"
        let modeValue = c.type == "work" ? "work" : "hobby"
        let person: SQLQueryString = """
            u.id::text AS id, \(unsafeRaw: PersonaSQL.expr("display_name", modeRef: mode)) AS display_name,
            \(unsafeRaw: PersonaSQL.expr("avatar_url", modeRef: mode)) AS avatar_url, u.avatar_color
            """
        let friendWhere: SQLQueryString = """
            FROM community_members cm JOIN users u ON u.id = cm.user_id
            WHERE cm.community_id = \(uuid: id) AND u.id <> \(uuid: viewer) AND u.deleted_at IS NULL
              AND EXISTS (SELECT 1 FROM connections k WHERE k.status = 'accepted' AND k.mode = \(bind: modeValue)
                AND ((k.requester_id = \(uuid: viewer) AND k.addressee_id = u.id)
                  OR (k.addressee_id = \(uuid: viewer) AND k.requester_id = u.id)))
            """
        let friends = try await db.raw("SELECT " + person + ", NULL::VARCHAR AS role " + friendWhere
                                       + " ORDER BY cm.joined_at DESC LIMIT 3").all(decoding: InfoPerson.self)
        struct N: Decodable { let n: Int }
        let friendsCount = try await db.raw("SELECT COUNT(*)::int AS n " + friendWhere).first(decoding: N.self)?.n ?? 0
        let staff = try await db.raw("""
            SELECT \(person), cm.role FROM community_members cm JOIN users u ON u.id = cm.user_id
            WHERE cm.community_id = \(uuid: id) AND cm.role IN ('admin', 'moderator') AND u.deleted_at IS NULL
            ORDER BY (cm.role = 'admin') DESC, cm.joined_at LIMIT 10
            """).all(decoding: InfoPerson.self)
        struct Activity: Decodable { let posts_today: Int; let posts_week: Int; let new_members_week: Int }
        let activity = try await db.raw("""
            SELECT
              (SELECT COUNT(*)::int FROM posts WHERE community_id = \(uuid: id) AND status = 'posted'
                 AND created_at >= date_trunc('day', NOW())) AS posts_today,
              (SELECT COUNT(*)::int FROM posts WHERE community_id = \(uuid: id) AND status = 'posted'
                 AND created_at >= NOW() - INTERVAL '7 days') AS posts_week,
              (SELECT COUNT(*)::int FROM community_members WHERE community_id = \(uuid: id)
                 AND joined_at >= NOW() - INTERVAL '7 days') AS new_members_week
            """).first(decoding: Activity.self)
        // A private community's about stays with its members (as on its page).
        let about = c.privacy == "private" && !c.is_member ? nil : c.description
        return CommunityInfo(about: about, privacy: c.privacy, created_at: c.created_at,
                             name_changed_at: c.name_changed_at, member_count: c.member_count,
                             friends: friends, friends_count: friendsCount, staff: staff,
                             posts_today: activity?.posts_today ?? 0, posts_week: activity?.posts_week ?? 0,
                             new_members_week: activity?.new_members_week ?? 0)
    }

    struct MemberRow: Content {
        var id: String
        var username: String
        var display_name: String
        @NullCoded var avatar_color: String?
        @NullCoded var job_title: String?
        @NullCoded var company: String?
        var role: String
        var joined_at: Date
    }
    static func members(_ communityID: String, limit: Int, offset: Int, on db: any SQLDatabase) async throws -> [MemberRow] {
        try await db.raw("""
            SELECT u.id::text AS id, u.username, u.display_name, u.avatar_color, u.job_title, u.company, cm.role, cm.joined_at
            FROM community_members cm JOIN users u ON u.id = cm.user_id
            WHERE cm.community_id = \(uuid: communityID)
            ORDER BY CASE cm.role WHEN 'admin' THEN 0 WHEN 'moderator' THEN 1 ELSE 2 END, cm.joined_at ASC
            LIMIT \(bind: limit) OFFSET \(bind: offset)
            """).all(decoding: MemberRow.self)
    }

    /// Public communities of one type, busiest first — with the viewer's own
    /// membership, so ones they've joined show as joined.
    static func trendingCommunities(type: String, limit: Int, viewer: String, on db: any SQLDatabase) async throws -> [CommunityRow] {
        try await db.raw("""
            SELECT \(rowColumns), cm.role, (cm.user_id IS NOT NULL) AS is_member,
              COALESCE(tr.score, 0)::float AS trending_score, (cm.pinned_at IS NOT NULL) AS is_pinned
            FROM communities c
            LEFT JOIN community_trending tr ON tr.community_id = c.id
            LEFT JOIN community_members cm ON cm.community_id = c.id AND cm.user_id = \(uuid: viewer)
            WHERE c.privacy = 'public' AND c.type = \(bind: type)
            ORDER BY COALESCE(tr.score, 0) DESC, c.member_count DESC LIMIT \(bind: limit)
            """).all(decoding: CommunityRow.self)
    }

    static func userHasInterests(_ userID: String, on db: any SQLDatabase) async throws -> Bool {
        struct One: Decodable { let one: Int }
        return try await db.raw("SELECT 1 AS one FROM recommendation_interests WHERE user_id = \(uuid: userID) LIMIT 1")
            .first(decoding: One.self) != nil
    }

    /// `getRecommendedCommunities` — interest-overlap scored. Response carries
    /// the extra `tag_overlap` / `rec_score` fields Node's `res.json(rows)` leaks.
    struct RecommendedRow: Content {
        var id: String
        @NullCoded var description: String?
        var name: String
        var type: String
        var privacy: String
        var icon_emoji: String
        @NullCoded var avatar_url: String?
        @NullCoded var cover_url: String?
        var cover_color: String
        var member_count: Int
        var post_count: Int
        var created_at: Date
        var is_member: Bool
        @NullCoded var role: String?
        var trending_score: Double
        var tag_overlap: Double
        var rec_score: Double
    }
    static func recommendedCommunities(_ userID: String, limit: Int, type: String, on db: any SQLDatabase) async throws -> [RecommendedRow] {
        let q: SQLQueryString = """
            WITH user_tags AS (SELECT tag, weight FROM recommendation_interests WHERE user_id = \(uuid: userID) ORDER BY weight DESC LIMIT 10)
            SELECT c.id::text AS id, c.name, c.description, c.type, c.privacy, c.icon_emoji, c.avatar_url, c.cover_url, c.cover_color,
              c.member_count, c.post_count, false AS is_member, NULL::VARCHAR AS role, c.created_at,
              COUNT(DISTINCT ct.tag)::FLOAT AS tag_overlap,
              COALESCE(tr.score, 0)::float AS trending_score,
              (COUNT(DISTINCT ct.tag)::FLOAT * 2.0 + COALESCE(tr.score, 0) * 0.5 + LN(GREATEST(c.member_count, 1)) * 0.3)::float AS rec_score
            FROM communities c
            JOIN community_tags ct ON ct.community_id = c.id
            JOIN user_tags ut ON ut.tag = ct.tag
            LEFT JOIN community_trending tr ON tr.community_id = c.id
            WHERE c.id NOT IN (SELECT community_id FROM community_members WHERE user_id = \(uuid: userID)) AND c.privacy = 'public'
              AND c.type = \(bind: type)
            """
        return try await db.raw(q + " GROUP BY c.id, tr.score ORDER BY rec_score DESC LIMIT \(bind: limit)")
            .all(decoding: RecommendedRow.self)
    }

    /// The viewer's communities (both modes; the app shows one): pinned
    /// first in the order they were pinned, then the most recently joined.
    static func byUser(_ userID: String, on db: any SQLDatabase) async throws -> [CommunityRow] {
        try await db.raw("""
            SELECT \(rowColumns), cm.role, true AS is_member, COALESCE(tr.score, 0)::float AS trending_score,
              (cm.pinned_at IS NOT NULL) AS is_pinned
            FROM communities c JOIN community_members cm ON cm.community_id = c.id
            LEFT JOIN community_trending tr ON tr.community_id = c.id
            WHERE cm.user_id = \(uuid: userID)
            ORDER BY (cm.pinned_at IS NULL), cm.pinned_at, cm.joined_at DESC
            """).all(decoding: CommunityRow.self)
    }

    static func search(searchQuery: String, type: String, tags: [String], sort: String, limit: Int, offset: Int, viewer: String, on db: any SQLDatabase) async throws -> [CommunityRow] {
        let like = "%\(searchQuery)%"
        var q: SQLQueryString = """
            SELECT \(rowColumns), cm.role, (cm.user_id IS NOT NULL) AS is_member,
              COALESCE(tr.score, 0)::float AS trending_score, (cm.pinned_at IS NOT NULL) AS is_pinned
            FROM communities c
            LEFT JOIN community_members cm ON cm.community_id = c.id AND cm.user_id = \(uuid: viewer)
            LEFT JOIN community_trending tr ON tr.community_id = c.id
            WHERE (c.name ILIKE \(bind: like) OR c.description ILIKE \(bind: like)) AND c.privacy = 'public'
              AND c.type = \(bind: type)
            """
        if !tags.isEmpty {
            q = q + " AND EXISTS (SELECT 1 FROM community_tags ct WHERE ct.community_id = c.id AND ct.tag = ANY(\(bind: tags)::text[]))"
        }
        switch sort {
        case "newest": q = q + " ORDER BY c.created_at DESC"
        case "trending": q = q + " ORDER BY COALESCE(tr.score, 0) DESC, c.member_count DESC"
        default: q = q + " ORDER BY c.member_count DESC, c.created_at DESC"
        }
        return try await db.raw(q + " LIMIT \(bind: limit) OFFSET \(bind: offset)").all(decoding: CommunityRow.self)
    }

    // MARK: join requests

    struct JoinRequestRow: Content {
        var id: String
        var requested_at: Date
        var status: String
        var user_id: String
        var username: String
        var display_name: String
        @NullCoded var avatar_color: String?
    }
    static func pendingRequests(_ communityID: String, limit: Int, offset: Int, on db: any SQLDatabase) async throws -> [JoinRequestRow] {
        try await db.raw("""
            SELECT jr.id::text AS id, jr.requested_at, jr.status,
              u.id::text AS user_id, u.username, u.display_name, u.avatar_color
            FROM community_join_requests jr JOIN users u ON u.id = jr.user_id
            WHERE jr.community_id = \(uuid: communityID) AND jr.status = 'pending'
            ORDER BY jr.requested_at ASC LIMIT \(bind: limit) OFFSET \(bind: offset)
            """).all(decoding: JoinRequestRow.self)
    }

    struct RequestByID: Decodable { let id: String; let community_id: String; let user_id: String; let status: String }
    static func requestByID(_ id: String, on db: any SQLDatabase) async throws -> RequestByID? {
        try await db.raw("SELECT id::text AS id, community_id::text AS community_id, user_id::text AS user_id, status FROM community_join_requests WHERE id = \(uuid: id)")
            .first(decoding: RequestByID.self)
    }
    static func hasExistingRequest(_ communityID: String, _ userID: String, on db: any SQLDatabase) async throws -> String? {
        struct R: Decodable { let status: String }
        return try await db.raw("SELECT status FROM community_join_requests WHERE community_id = \(uuid: communityID) AND user_id = \(uuid: userID)")
            .first(decoding: R.self)?.status
    }
    struct CreatedRequest: Decodable { let id: String }
    static func createRequest(_ communityID: String, _ userID: String, on db: any SQLDatabase) async throws -> String {
        try await db.raw("""
            INSERT INTO community_join_requests (community_id, user_id) VALUES (\(uuid: communityID), \(uuid: userID))
            ON CONFLICT (community_id, user_id) DO UPDATE SET status = 'pending', requested_at = NOW(), reviewed_by = NULL, reviewed_at = NULL
            RETURNING id::text AS id
            """).first(decoding: CreatedRequest.self)!.id
    }
    static func deleteRequest(_ communityID: String, _ userID: String, on db: any SQLDatabase) async throws {
        try await db.raw("DELETE FROM community_join_requests WHERE community_id = \(uuid: communityID) AND user_id = \(uuid: userID)").run()
    }
    /// Review fix: status-guarded. Returns the updated row or nil.
    struct ReviewedRow: Content {
        var id: String; var community_id: String; var user_id: String; var status: String
        @NullCoded var reviewed_by: String?; @NullCoded var reviewed_at: Date?; var requested_at: Date
    }
    static func reviewRequest(_ id: String, reviewerID: String, status: String, on db: any SQLDatabase) async throws -> ReviewedRow? {
        try await db.raw("""
            UPDATE community_join_requests SET status = \(bind: status), reviewed_by = \(uuid: reviewerID), reviewed_at = NOW()
            WHERE id = \(uuid: id) AND status = 'pending'
            RETURNING id::text AS id, community_id::text AS community_id, user_id::text AS user_id, status,
              reviewed_by::text AS reviewed_by, reviewed_at, requested_at
            """).first(decoding: ReviewedRow.self)
    }

    // MARK: pin / kick / role

    static func pinPost(_ postID: String, _ communityID: String, adminID: String, on db: any SQLDatabase) async throws -> Bool {
        try await db.raw("UPDATE posts SET is_pinned = FALSE, pinned_at = NULL, pinned_by = NULL WHERE community_id = \(uuid: communityID) AND is_pinned = TRUE").run()
        struct R: Decodable { let id: String }
        return try await db.raw("""
            UPDATE posts SET is_pinned = TRUE, pinned_at = NOW(), pinned_by = \(uuid: adminID)
            WHERE id = \(uuid: postID) AND community_id = \(uuid: communityID) AND status = 'posted' RETURNING id
            """).first(decoding: R.self) != nil
    }
    static func unpinPost(_ postID: String, _ communityID: String, on db: any SQLDatabase) async throws -> Bool {
        struct R: Decodable { let id: String }
        return try await db.raw("""
            UPDATE posts SET is_pinned = FALSE, pinned_at = NULL, pinned_by = NULL
            WHERE id = \(uuid: postID) AND community_id = \(uuid: communityID) RETURNING id
            """).first(decoding: R.self) != nil
    }
    static func kickMember(_ communityID: String, _ targetID: String, on db: any SQLDatabase) async throws -> Bool {
        struct R: Decodable { let user_id: String }
        return try await db.raw("DELETE FROM community_members WHERE community_id = \(uuid: communityID) AND user_id = \(uuid: targetID) RETURNING user_id::text AS user_id")
            .first(decoding: R.self) != nil
    }
    /// Partial update — a nil field is left untouched (only non-nil fields are
    /// written), same convention as `UserQueries.updateProfile`. Returns false
    /// when nothing matched `id` (already-deleted community).
    static func update(_ id: String, name: String?, description: String?, privacy: String?,
                        iconEmoji: String?, coverColor: String?, avatarURL: String?,
                        coverURL: String? = nil, requirePostApproval: Bool? = nil, on db: any SQLDatabase) async throws -> Bool {
        var sets: [SQLQueryString] = []
        if let name {
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            sets.append("name = \(bind: trimmed)")
            // "Name last changed on …" on the info page — only a real change counts.
            sets.append("name_changed_at = CASE WHEN name IS DISTINCT FROM \(bind: trimmed) THEN NOW() ELSE name_changed_at END")
        }
        if let coverURL { sets.append("cover_url = \(bind: coverURL.trimmingCharacters(in: .whitespaces).nilIfEmpty)") }
        if let requirePostApproval { sets.append("require_post_approval = \(bind: requirePostApproval)") }
        if let description { sets.append("description = \(bind: description.trimmingCharacters(in: .whitespaces).nilIfEmpty)") }
        if let privacy { sets.append("privacy = \(bind: privacy)") }
        if let iconEmoji { sets.append("icon_emoji = \(bind: iconEmoji)") }
        if let coverColor { sets.append("cover_color = \(bind: coverColor)") }
        if let avatarURL { sets.append("avatar_url = \(bind: avatarURL.trimmingCharacters(in: .whitespaces).nilIfEmpty)") }
        guard !sets.isEmpty else { return true }
        var q: SQLQueryString = "UPDATE communities SET "
        for (i, s) in sets.enumerated() {
            if i > 0 { q = q + ", " }
            q = q + s
        }
        q = q + ", updated_at = NOW() WHERE id = \(uuid: id) RETURNING id"
        struct R: Decodable { let id: String }
        return try await db.raw(q).first(decoding: R.self) != nil
    }

    struct RoleRow: Content { var community_id: String; var user_id: String; var role: String; var joined_at: Date }
    static func updateRole(_ communityID: String, _ targetID: String, _ newRole: String, on db: any SQLDatabase) async throws -> RoleRow? {
        try await db.raw("""
            UPDATE community_members SET role = \(bind: newRole)
            WHERE community_id = \(uuid: communityID) AND user_id = \(uuid: targetID)
            RETURNING community_id::text AS community_id, user_id::text AS user_id, role, joined_at
            """).first(decoding: RoleRow.self)
    }
}

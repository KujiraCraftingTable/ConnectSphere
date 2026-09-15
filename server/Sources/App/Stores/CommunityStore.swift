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
        var cover_color: String
        var member_count: Int
        var post_count: Int
        var created_at: Date
        var created_by: String
        var is_member: Bool
        @NullCoded var role: String?
        @NullCoded var join_request_status: String?
        /// Feed-visibility mute — false for a non-member (nothing to mute).
        var is_muted: Bool
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
        var cover_color: String
        var member_count: Int
        var post_count: Int
        var created_at: Date
        @NullCoded var role: String?
        var is_member: Bool?
        var trending_score: Double?
    }

    static func byID(_ id: String, viewer: String?, on db: any SQLDatabase) async throws -> CommunityDetail? {
        let q: SQLQueryString
        if let viewer {
            q = """
                SELECT c.id::text AS id, c.name, c.description, c.type, c.privacy, c.icon_emoji, c.avatar_url, c.cover_color,
                  c.member_count, c.post_count, c.created_by::text AS created_by, c.created_at,
                  (cm.user_id IS NOT NULL) AS is_member, cm.role, jr.status AS join_request_status,
                  COALESCE(cm.muted, false) AS is_muted
                FROM communities c
                LEFT JOIN community_members cm ON cm.community_id = c.id AND cm.user_id = \(uuid: viewer)
                LEFT JOIN community_join_requests jr ON jr.community_id = c.id AND jr.user_id = \(uuid: viewer)
                WHERE c.id = \(uuid: id)
                """
        } else {
            q = """
                SELECT c.id::text AS id, c.name, c.description, c.type, c.privacy, c.icon_emoji, c.avatar_url, c.cover_color,
                  c.member_count, c.post_count, c.created_by::text AS created_by, c.created_at,
                  false AS is_member, NULL::VARCHAR AS role, NULL::VARCHAR AS join_request_status,
                  false AS is_muted
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

    /// `getTrendingCommunities` — hardcodes `is_member=false`, `role=null`.
    static func trendingCommunities(type: String?, limit: Int, on db: any SQLDatabase) async throws -> [CommunityRow] {
        struct R: Decodable {
            let id: String; let name: String; let description: String?; let type: String; let privacy: String
            let icon_emoji: String; let avatar_url: String?; let cover_color: String; let member_count: Int; let post_count: Int
            let created_at: Date; let trending_score: Double
        }
        var q: SQLQueryString = """
            SELECT c.id::text AS id, c.name, c.description, c.type, c.privacy, c.icon_emoji, c.avatar_url, c.cover_color,
              c.member_count, c.post_count, c.created_at, COALESCE(tr.score, 0)::float AS trending_score
            FROM communities c LEFT JOIN community_trending tr ON tr.community_id = c.id
            WHERE c.privacy = 'public'
            """
        if let type { q = q + " AND c.type = \(bind: type)" }
        q = q + " ORDER BY COALESCE(tr.score, 0) DESC, c.member_count DESC LIMIT \(bind: limit)"
        return try await db.raw(q).all(decoding: R.self).map {
            CommunityRow(id: $0.id, description: $0.description, name: $0.name, type: $0.type, privacy: $0.privacy,
                icon_emoji: $0.icon_emoji, avatar_url: $0.avatar_url, cover_color: $0.cover_color, member_count: $0.member_count, post_count: $0.post_count,
                created_at: $0.created_at, role: nil, is_member: false, trending_score: $0.trending_score)
        }
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
    static func recommendedCommunities(_ userID: String, limit: Int, on db: any SQLDatabase) async throws -> [RecommendedRow] {
        try await db.raw("""
            WITH user_tags AS (SELECT tag, weight FROM recommendation_interests WHERE user_id = \(uuid: userID) ORDER BY weight DESC LIMIT 10)
            SELECT c.id::text AS id, c.name, c.description, c.type, c.privacy, c.icon_emoji, c.avatar_url, c.cover_color,
              c.member_count, c.post_count, false AS is_member, NULL::VARCHAR AS role, c.created_at,
              COUNT(DISTINCT ct.tag)::FLOAT AS tag_overlap,
              COALESCE(tr.score, 0)::float AS trending_score,
              (COUNT(DISTINCT ct.tag)::FLOAT * 2.0 + COALESCE(tr.score, 0) * 0.5 + LN(GREATEST(c.member_count, 1)) * 0.3)::float AS rec_score
            FROM communities c
            JOIN community_tags ct ON ct.community_id = c.id
            JOIN user_tags ut ON ut.tag = ct.tag
            LEFT JOIN community_trending tr ON tr.community_id = c.id
            WHERE c.id NOT IN (SELECT community_id FROM community_members WHERE user_id = \(uuid: userID)) AND c.privacy = 'public'
            GROUP BY c.id, tr.score
            ORDER BY rec_score DESC LIMIT \(bind: limit)
            """).all(decoding: RecommendedRow.self)
    }

    static func byUser(_ userID: String, on db: any SQLDatabase) async throws -> [CommunityRow] {
        struct R: Decodable {
            let id: String; let name: String; let description: String?; let type: String; let privacy: String
            let icon_emoji: String; let avatar_url: String?; let cover_color: String; let member_count: Int; let post_count: Int
            let created_at: Date; let role: String
        }
        let rows = try await db.raw("""
            SELECT c.id::text AS id, c.name, c.description, c.type, c.privacy, c.icon_emoji, c.avatar_url, c.cover_color,
              c.member_count, c.post_count, c.created_at, cm.role
            FROM communities c JOIN community_members cm ON cm.community_id = c.id
            WHERE cm.user_id = \(uuid: userID) ORDER BY cm.joined_at DESC
            """).all(decoding: R.self)
        return rows.map { CommunityRow(id: $0.id, description: $0.description, name: $0.name, type: $0.type, privacy: $0.privacy,
            icon_emoji: $0.icon_emoji, avatar_url: $0.avatar_url, cover_color: $0.cover_color, member_count: $0.member_count, post_count: $0.post_count,
            created_at: $0.created_at, role: $0.role, is_member: nil, trending_score: nil) }
    }

    static func search(searchQuery: String, type: String?, tags: [String], sort: String, limit: Int, offset: Int, viewer: String, on db: any SQLDatabase) async throws -> [CommunityRow] {
        struct R: Decodable {
            let id: String; let name: String; let description: String?; let type: String; let privacy: String
            let icon_emoji: String; let avatar_url: String?; let cover_color: String; let member_count: Int; let post_count: Int
            let created_at: Date; let is_member: Bool; let role: String?; let trending_score: Double
        }
        let like = "%\(searchQuery)%"
        var q: SQLQueryString = """
            SELECT c.id::text AS id, c.name, c.description, c.type, c.privacy, c.icon_emoji, c.avatar_url, c.cover_color,
              c.member_count, c.post_count, c.created_at,
              (cm.user_id IS NOT NULL) AS is_member, cm.role,
              COALESCE(tr.score, 0)::float AS trending_score
            FROM communities c
            LEFT JOIN community_members cm ON cm.community_id = c.id AND cm.user_id = \(uuid: viewer)
            LEFT JOIN community_trending tr ON tr.community_id = c.id
            WHERE (c.name ILIKE \(bind: like) OR c.description ILIKE \(bind: like)) AND c.privacy = 'public'
            """
        if let type { q = q + " AND c.type = \(bind: type)" }
        if !tags.isEmpty {
            q = q + " AND EXISTS (SELECT 1 FROM community_tags ct WHERE ct.community_id = c.id AND ct.tag = ANY(\(bind: tags)::text[]))"
        }
        switch sort {
        case "newest": q = q + " ORDER BY c.created_at DESC"
        case "trending": q = q + " ORDER BY COALESCE(tr.score, 0) DESC, c.member_count DESC"
        default: q = q + " ORDER BY c.member_count DESC, c.created_at DESC"
        }
        q = q + " LIMIT \(bind: limit) OFFSET \(bind: offset)"
        let rows = try await db.raw(q).all(decoding: R.self)
        return rows.map { CommunityRow(id: $0.id, description: $0.description, name: $0.name, type: $0.type, privacy: $0.privacy,
            icon_emoji: $0.icon_emoji, avatar_url: $0.avatar_url, cover_color: $0.cover_color, member_count: $0.member_count, post_count: $0.post_count,
            created_at: $0.created_at, role: $0.role, is_member: $0.is_member, trending_score: $0.trending_score) }
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
            WHERE id = \(uuid: postID) AND community_id = \(uuid: communityID) RETURNING id
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
                        iconEmoji: String?, coverColor: String?, avatarURL: String?, on db: any SQLDatabase) async throws -> Bool {
        var sets: [SQLQueryString] = []
        if let name { sets.append("name = \(bind: name.trimmingCharacters(in: .whitespaces))") }
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

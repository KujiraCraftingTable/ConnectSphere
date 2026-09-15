import Vapor
import SQLKit

/// Raw-SQL data access for posts — port of `backend/src/models/postModel.js`.
/// The JSON sub-objects (`author`, `shared_post`, `event_data`, `poll_data`,
/// `tags`) are selected as `::text` and parsed with `JSONCoding.makeDecoder()`
/// (the tolerant ISO-8601 strategy) — PostgresKit's built-in JSON decoder uses
/// a numeric date strategy and would choke on the string timestamps.
enum PostStore {
    static let maxHashtagsPerPost = 10

    /// Port of `sanitizeHashtags` — strip all whitespace, cap 100 chars, cap 10
    /// tags, case-insensitive dedupe (first casing wins).
    static func sanitizeHashtags(_ tags: [String]?) -> [String] {
        guard let tags else { return [] }
        var seen = Set<String>()
        var out: [String] = []
        for raw in tags {
            if out.count >= maxHashtagsPerPost { break }
            let trimmed = String(raw.filter { !$0.isWhitespace }.prefix(100))
            if trimmed.isEmpty { continue }
            let key = trimmed.lowercased()
            if seen.contains(key) { continue }
            seen.insert(key)
            out.append(trimmed)
        }
        return out
    }

    // MARK: buildPostSelect + clauses  (viewer id inlined via \(uuid:) at each use)

    static func buildPostSelect(_ v: String) -> SQLQueryString {
        let dnP  = PersonaSQL.expr("display_name", modeRef: "p.mode")
        let avP  = PersonaSQL.expr("avatar_url", modeRef: "p.mode")
        let dnSp = PersonaSQL.expr("display_name", modeRef: "sp.mode", alias: "su")
        let avSp = PersonaSQL.expr("avatar_url", modeRef: "sp.mode", alias: "su")
        return """
        SELECT
          p.id::text AS id, p.content, p.mode, p.privacy, p.image_urls[1] AS image_url, p.image_urls, p.article_title, p.link_url,
          p.like_count, p.comment_count, p.share_count, p.created_at,
          p.post_type, p.is_pinned, p.pinned_at, p.shared_post_id::text AS shared_post_id,
          EXISTS(SELECT 1 FROM post_likes pl WHERE pl.post_id = p.id AND pl.user_id = \(uuid: v)) AS is_liked,
          EXISTS(SELECT 1 FROM saved_posts sp2 WHERE sp2.post_id = p.id AND sp2.user_id = \(uuid: v)) AS is_saved,
          (CASE WHEN p.shared_post_id IS NOT NULL THEN (
            SELECT json_build_object(
              'id', sp.id, 'content', sp.content, 'image_url', sp.image_urls[1], 'image_urls', sp.image_urls,
              'link_url', sp.link_url, 'article_title', sp.article_title, 'created_at', sp.created_at,
              'author', json_build_object('id', su.id, 'username', su.username,
                'display_name', \(unsafeRaw: dnSp), 'avatar_color', su.avatar_color, 'avatar_url', \(unsafeRaw: avSp)))
            FROM posts sp JOIN users su ON su.id = sp.author_id
            WHERE sp.id = p.shared_post_id AND sp.status = 'posted'
              AND (sp.privacy = 'public' OR sp.author_id = \(uuid: v)
                OR (sp.privacy = 'friends' AND EXISTS (SELECT 1 FROM connections c WHERE c.status = 'accepted'
                     AND ((c.requester_id = sp.author_id AND c.addressee_id = \(uuid: v))
                       OR (c.addressee_id = sp.author_id AND c.requester_id = \(uuid: v))))))
              AND (sp.community_id IS NULL OR sp.author_id = \(uuid: v)
                OR EXISTS (SELECT 1 FROM communities co WHERE co.id = sp.community_id AND co.privacy = 'public')
                OR EXISTS (SELECT 1 FROM community_members cm WHERE cm.community_id = sp.community_id AND cm.user_id = \(uuid: v)))
          ) ELSE NULL END)::text AS shared_post,
          COALESCE(json_agg(DISTINCT pt.tag) FILTER (WHERE pt.tag IS NOT NULL AND (pt.source = 'user' OR p.show_ai_tags)), '[]')::text AS tags,
          json_build_object('id', u.id, 'username', u.username, 'display_name', \(unsafeRaw: dnP),
            'avatar_color', u.avatar_color, 'avatar_url', \(unsafeRaw: avP),
            'job_title', u.job_title, 'company', u.company)::text AS author,
          (CASE WHEN p.post_type = 'event' THEN (
            SELECT json_build_object('id', ce.id, 'title', ce.title, 'location', ce.location,
              'starts_at', ce.starts_at, 'ends_at', ce.ends_at, 'rsvp_count', ce.rsvp_count,
              'user_rsvp', (SELECT er.status FROM event_rsvps er WHERE er.event_id = ce.id AND er.user_id = \(uuid: v)))
            FROM community_events ce WHERE ce.post_id = p.id
          ) ELSE NULL END)::text AS event_data,
          (CASE WHEN p.post_type = 'poll' THEN json_build_object(
            'options', (SELECT json_agg(json_build_object('id', po.id, 'text', po.text, 'vote_count', po.vote_count,
              'position', po.position, 'ends_at', po.ends_at) ORDER BY po.position) FROM poll_options po WHERE po.post_id = p.id),
            'user_vote', (SELECT pv.poll_option_id::TEXT FROM poll_votes pv JOIN poll_options po2 ON po2.id = pv.poll_option_id
              WHERE po2.post_id = p.id AND pv.user_id = \(uuid: v)))
          ELSE NULL END)::text AS poll_data
        FROM posts p
        JOIN users u ON u.id = p.author_id
        LEFT JOIN post_tags pt ON pt.post_id = p.id
        """
    }

    static func privacyClause(_ v: String) -> SQLQueryString {
        """
        (p.privacy = 'public' OR p.author_id = \(uuid: v)
         OR (p.privacy = 'friends' AND EXISTS (SELECT 1 FROM connections c WHERE c.status = 'accepted'
              AND ((c.requester_id = p.author_id AND c.addressee_id = \(uuid: v))
                OR (c.addressee_id = p.author_id AND c.requester_id = \(uuid: v))))))
        """
    }
    static func communityVisibilityClause(_ v: String) -> SQLQueryString {
        """
        (p.community_id IS NULL OR p.author_id = \(uuid: v)
         OR EXISTS (SELECT 1 FROM communities co WHERE co.id = p.community_id AND co.privacy = 'public')
         OR EXISTS (SELECT 1 FROM community_members cm WHERE cm.community_id = p.community_id AND cm.user_id = \(uuid: v)))
        """
    }
    static func notBlockedClause(_ v: String) -> SQLQueryString {
        """
        NOT EXISTS (SELECT 1 FROM user_blocks ub
          WHERE (ub.blocker_id = \(uuid: v) AND ub.blocked_id = p.author_id)
             OR (ub.blocker_id = p.author_id AND ub.blocked_id = \(uuid: v)))
        """
    }
    static func notHiddenClause(_ v: String) -> SQLQueryString {
        "NOT EXISTS (SELECT 1 FROM hidden_posts hp WHERE hp.user_id = \(uuid: v) AND hp.post_id = p.id)"
    }
    static func connectionsOnlyClause(_ v: String) -> SQLQueryString {
        """
        (p.author_id = \(uuid: v) OR EXISTS (SELECT 1 FROM connections c2 WHERE c2.status = 'accepted'
          AND ((c2.requester_id = p.author_id AND c2.addressee_id = \(uuid: v))
            OR (c2.addressee_id = p.author_id AND c2.requester_id = \(uuid: v)))))
        """
    }

    // MARK: row → PostObject

    struct PostRow: Decodable {
        var id: String
        var content: String?
        var mode: String
        var privacy: String
        var image_url: String?
        var image_urls: [String]?
        var article_title: String?
        var link_url: String?
        var like_count: Int
        var comment_count: Int
        var share_count: Int
        var created_at: Date
        var post_type: String
        var is_pinned: Bool
        var pinned_at: Date?
        var shared_post_id: String?
        var is_liked: Bool
        var is_saved: Bool
        var shared_post: String?
        var tags: String
        var author: String
        var event_data: String?
        var poll_data: String?
        var community: String?
    }

    static func map(_ r: PostRow) throws -> PostObject {
        let dec = JSONCoding.makeDecoder()
        func parse<T: Decodable>(_ s: String?, _ t: T.Type) throws -> T? {
            guard let s, s != "null" else { return nil }
            return try dec.decode(T.self, from: Data(s.utf8))
        }
        return PostObject(
            id: r.id, content: r.content, mode: r.mode, privacy: r.privacy,
            image_url: r.image_url, image_urls: r.image_urls, article_title: r.article_title, link_url: r.link_url,
            like_count: r.like_count, comment_count: r.comment_count, share_count: r.share_count,
            created_at: r.created_at, post_type: r.post_type, is_pinned: r.is_pinned, pinned_at: r.pinned_at,
            shared_post_id: r.shared_post_id, is_liked: r.is_liked, is_saved: r.is_saved,
            shared_post: try parse(r.shared_post, PostObject.SharedPost.self),
            tags: (try? dec.decode([String].self, from: Data(r.tags.utf8))) ?? [],
            author: try dec.decode(PostObject.PostAuthor.self, from: Data(r.author.utf8)),
            event_data: try parse(r.event_data, PostObject.EventData.self),
            poll_data: try parse(r.poll_data, PostObject.PollData.self),
            community: try parse(r.community, PostObject.CommunityRef.self)
        )
    }

    // MARK: queries

    struct FeedFilters {
        var mode: String?
        var authorID: String?
        var tag: String?
        var connectionsOnly: Bool
        var limit: Int
        var offset: Int
    }

    private static func feedWhere(_ v: String, _ f: FeedFilters) -> SQLQueryString {
        var w: SQLQueryString = "WHERE p.status = 'posted' AND p.community_id IS NULL AND "
        w = w + privacyClause(v) + " AND " + notBlockedClause(v) + " AND " + notHiddenClause(v)
        if f.connectionsOnly { w = w + " AND " + connectionsOnlyClause(v) }
        if let m = f.mode { w = w + " AND p.mode = \(bind: m)" }
        if let a = f.authorID { w = w + " AND p.author_id = \(uuid: a)" }
        if let t = f.tag {
            w = w + " AND EXISTS (SELECT 1 FROM post_tags ptf WHERE ptf.post_id = p.id AND LOWER(ptf.tag) = LOWER(\(bind: t)) AND (ptf.source = 'user' OR p.show_ai_tags))"
        }
        return w
    }

    static func findAll(viewer: String, _ f: FeedFilters, on db: any SQLDatabase) async throws -> [PostObject] {
        let q = buildPostSelect(viewer) + " " + feedWhere(viewer, f)
            + " GROUP BY p.id, u.id ORDER BY p.created_at DESC LIMIT \(bind: f.limit) OFFSET \(bind: f.offset)"
        return try await db.raw(q).all(decoding: PostRow.self).map(map)
    }

    static func countAll(viewer: String, _ f: FeedFilters, on db: any SQLDatabase) async throws -> Int {
        struct N: Decodable { let n: Int }
        let q: SQLQueryString = "SELECT COUNT(*)::int AS n FROM posts p " + feedWhere(viewer, f)
        return try await db.raw(q).first(decoding: N.self)?.n ?? 0
    }

    static func findById(_ id: String, viewer: String, on db: any SQLDatabase) async throws -> PostObject? {
        let q = buildPostSelect(viewer)
            + " WHERE p.id = \(uuid: id) AND p.status = 'posted' AND "
            + privacyClause(viewer) + " AND " + notBlockedClause(viewer) + " AND " + communityVisibilityClause(viewer)
            + " GROUP BY p.id, u.id"
        guard let row = try await db.raw(q).first(decoding: PostRow.self) else { return nil }
        return try map(row)
    }

    struct PostMeta: Decodable {
        var id: String
        var author_id: String
        var community_id: String?
        var post_type: String
    }
    static func findMeta(_ id: String, on db: any SQLDatabase) async throws -> PostMeta? {
        try await db.raw("SELECT id, author_id, community_id, post_type FROM posts WHERE id = \(uuid: id)")
            .first(decoding: PostMeta.self)
    }

    // MARK: create

    struct CreateArgs {
        var authorID: String
        var content: String
        var mode: String
        var privacy: String
        var imageUrl: String?
        var imageUrls: [String]?
        var linkUrl: String?
        var articleTitle: String?
        var sharedPostID: String?
        var hashtags: [String]
        var showAiTags: Bool
    }

    static func create(_ a: CreateArgs, on db: AppDatabase) async throws -> PostObject? {
        let validPrivacy = ["public", "friends", "only_me"].contains(a.privacy) ? a.privacy : "public"
        let urls: [String]? = (a.imageUrls?.isEmpty == false) ? a.imageUrls : (a.imageUrl.map { [$0] })
        var newID = ""
        try await db.tx { t in
            struct R: Decodable { let id: String }
            let row = try await t.raw("""
                INSERT INTO posts (author_id, content, mode, privacy, image_urls, link_url, article_title, shared_post_id, show_ai_tags)
                VALUES (\(uuid: a.authorID), \(bind: a.content), \(bind: a.mode), \(bind: validPrivacy),
                        \(bind: urls), \(bind: a.linkUrl), \(bind: a.articleTitle), \(uuid: a.sharedPostID), \(bind: a.showAiTags))
                RETURNING id
                """).first(decoding: R.self)
            newID = row!.id
            try await t.raw("UPDATE users SET post_count = post_count + 1 WHERE id = \(uuid: a.authorID)").run()
            let clean = sanitizeHashtags(a.hashtags)
            if !clean.isEmpty {
                try await t.raw("""
                    INSERT INTO post_tags (post_id, tag, source)
                    SELECT \(uuid: newID), UNNEST(\(bind: clean)::text[]), 'user'
                    ON CONFLICT (post_id, tag) DO NOTHING
                    """).run()
            }
        }
        return try await findById(newID, viewer: a.authorID, on: db.sql())
    }

    // MARK: update / delete / restore / lists

    /// Returns `.updated(post)`, `.notFound`, or `.empty`.
    enum UpdateResult { case updated(PostObject); case notFound; case empty }

    static func updatePost(
        _ id: String, content: String?, contentProvided: Bool, privacy: String?,
        imageUrl: String?, imageUrls: [String]?, linkUrl: String?, articleTitle: String?,
        on db: any SQLDatabase
    ) async throws -> UpdateResult {
        let validPrivacy = ["public", "friends", "only_me"].contains(privacy ?? "") ? privacy : nil
        let urls: [String]? = (imageUrls?.isEmpty == false) ? imageUrls : (imageUrl.map { [$0] })

        struct C: Decodable { let content: String? }
        guard let existing = try await db.raw("SELECT content FROM posts WHERE id = \(uuid: id) AND status = 'posted'")
            .first(decoding: C.self) else { return .notFound }

        let finalContent = contentProvided ? content : existing.content
        let hasContent = !(finalContent?.trimmingCharacters(in: .whitespaces).isEmpty ?? true)
        let hasImages = (urls?.isEmpty == false)
        let hasLink = !(linkUrl?.isEmpty ?? true)
        if !hasContent && !hasImages && !hasLink { return .empty }

        struct R: Decodable { let id: String; let author_id: String }
        guard let row = try await db.raw("""
            UPDATE posts SET
              content = CASE WHEN \(bind: contentProvided) THEN \(bind: contentProvided ? content : nil) ELSE content END,
              privacy = COALESCE(\(bind: validPrivacy), privacy),
              image_urls = \(bind: urls), link_url = \(bind: linkUrl), article_title = \(bind: articleTitle),
              updated_at = NOW()
            WHERE id = \(uuid: id) AND status = 'posted'
            RETURNING id, author_id
            """).first(decoding: R.self) else { return .notFound }
        guard let post = try await findById(row.id, viewer: row.author_id, on: db) else { return .notFound }
        return .updated(post)
    }

    struct DeleteRow: Decodable { let id: String; let author_id: String; let community_id: String? }

    static func softDelete(_ id: String, on db: any SQLDatabase) async throws -> DeleteRow? {
        guard let row = try await db.raw("""
            UPDATE posts SET status = 'deleted', deleted_at = NOW(), updated_at = NOW()
            WHERE id = \(uuid: id) AND status = 'posted'
            RETURNING id, author_id, community_id
            """).first(decoding: DeleteRow.self) else { return nil }
        try await db.raw("UPDATE users SET post_count = GREATEST(post_count - 1, 0) WHERE id = \(uuid: row.author_id)").run()
        return row
    }

    static func restore(_ id: String, requester: String, on db: any SQLDatabase) async throws -> PostObject? {
        guard let row = try await db.raw("""
            UPDATE posts SET status = 'posted', deleted_at = NULL, updated_at = NOW()
            WHERE id = \(uuid: id) AND author_id = \(uuid: requester) AND status = 'deleted'
            RETURNING id, author_id, community_id
            """).first(decoding: DeleteRow.self) else { return nil }
        try await db.raw("UPDATE users SET post_count = post_count + 1 WHERE id = \(uuid: row.author_id)").run()
        return try await findById(row.id, viewer: requester, on: db)
    }

    static func listDeleted(_ userID: String, limit: Int, offset: Int, on db: any SQLDatabase) async throws -> [PostObject] {
        let q = buildPostSelect(userID)
            + " WHERE p.author_id = \(uuid: userID) AND p.status = 'deleted' GROUP BY p.id, u.id"
            + " ORDER BY MAX(p.deleted_at) DESC LIMIT \(bind: limit) OFFSET \(bind: offset)"
        return try await db.raw(q).all(decoding: PostRow.self).map(map)
    }

    /// Port of `getPostsByCommunity` — buildPostSelect wrapped so the embedded
    /// `community` object can be merged in; pinned post first.
    static func getPostsByCommunity(_ communityID: String, viewer: String, tag: String?, limit: Int, offset: Int, on db: any SQLDatabase) async throws -> [PostObject] {
        var q = "SELECT sub.*, (SELECT json_build_object('id', co.id, 'name', co.name, 'icon_emoji', co.icon_emoji, 'avatar_url', co.avatar_url) FROM communities co WHERE co.id = " as SQLQueryString
        q = q + "\(uuid: communityID))::text AS community FROM ("
        q = q + buildPostSelect(viewer)
        q = q + " WHERE p.community_id = \(uuid: communityID) AND p.status = 'posted'"
        if let tag {
            q = q + " AND EXISTS (SELECT 1 FROM post_tags ptf WHERE ptf.post_id = p.id AND LOWER(ptf.tag) = LOWER(\(bind: tag)) AND (ptf.source = 'user' OR p.show_ai_tags))"
        }
        q = q + " GROUP BY p.id, u.id) sub ORDER BY sub.is_pinned DESC, sub.created_at DESC LIMIT \(bind: limit) OFFSET \(bind: offset)"
        return try await db.raw(q).all(decoding: PostRow.self).map(map)
    }

    static func listSaved(_ userID: String, limit: Int, offset: Int, on db: any SQLDatabase) async throws -> [PostObject] {
        let q = buildPostSelect(userID)
            + " JOIN saved_posts sap ON sap.post_id = p.id AND sap.user_id = \(uuid: userID)"
            + " WHERE p.status = 'posted' AND " + privacyClause(userID) + " AND " + notBlockedClause(userID)
            + " AND " + communityVisibilityClause(userID)
            + " GROUP BY p.id, u.id, sap.created_at ORDER BY sap.created_at DESC LIMIT \(bind: limit) OFFSET \(bind: offset)"
        return try await db.raw(q).all(decoding: PostRow.self).map(map)
    }
}

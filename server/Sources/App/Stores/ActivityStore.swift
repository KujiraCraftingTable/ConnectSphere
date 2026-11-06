import Vapor
import SQLKit

/// Your activity log: comments you wrote and things you liked, both modes,
/// newest first, only on posts you can still see.
enum ActivityStore {
    struct Item: Content {
        /// comment | post_like | comment_like
        var kind: String
        var id: String
        var created_at: Date
        var mode: String
        var post_id: String
        var post_excerpt: String
        var post_author_name: String
        @NullCoded var comment_id: String?
        @NullCoded var comment_excerpt: String?
    }

    private static func visible(_ me: String) -> SQLQueryString {
        "p.status = 'posted' AND " + PostStore.privacyClause(me) + " AND " + PostStore.notBlockedClause(me)
    }

    private static let author = PersonaSQL.expr("display_name", modeRef: "p.mode", alias: "au")

    static func comments(of me: String, offset: Int, limit: Int, on db: any SQLDatabase) async throws -> [Item] {
        let q: SQLQueryString = """
            SELECT 'comment' AS kind, c.id::text AS id, c.created_at, p.mode, p.id::text AS post_id,
              LEFT(COALESCE(p.content, ''), 140) AS post_excerpt, \(unsafeRaw: author) AS post_author_name,
              c.id::text AS comment_id, LEFT(COALESCE(c.content, ''), 200) AS comment_excerpt
            FROM comments c JOIN posts p ON p.id = c.post_id JOIN users au ON au.id = p.author_id
            WHERE c.author_id = \(uuid: me) AND c.deleted_at IS NULL AND
            """
        return try await db.raw(q + " " + visible(me)
                                + " ORDER BY c.created_at DESC, c.id LIMIT \(bind: limit) OFFSET \(bind: offset)")
            .all(decoding: Item.self)
    }

    static func reactions(of me: String, offset: Int, limit: Int, on db: any SQLDatabase) async throws -> [Item] {
        let posts: SQLQueryString = """
            SELECT 'post_like' AS kind, (l.post_id::text || ':' || l.user_id::text) AS id, l.created_at, p.mode,
              p.id::text AS post_id, LEFT(COALESCE(p.content, ''), 140) AS post_excerpt,
              \(unsafeRaw: author) AS post_author_name, NULL::text AS comment_id, NULL::text AS comment_excerpt
            FROM post_likes l JOIN posts p ON p.id = l.post_id JOIN users au ON au.id = p.author_id
            WHERE l.user_id = \(uuid: me) AND
            """
        let comments: SQLQueryString = """
            SELECT 'comment_like' AS kind, (cl.comment_id::text || ':' || cl.user_id::text) AS id, cl.created_at, p.mode,
              p.id::text AS post_id, LEFT(COALESCE(p.content, ''), 140) AS post_excerpt,
              \(unsafeRaw: author) AS post_author_name, c.id::text AS comment_id, LEFT(COALESCE(c.content, ''), 200) AS comment_excerpt
            FROM comment_likes cl JOIN comments c ON c.id = cl.comment_id AND c.deleted_at IS NULL
            JOIN posts p ON p.id = c.post_id JOIN users au ON au.id = p.author_id
            WHERE cl.user_id = \(uuid: me) AND
            """
        let q: SQLQueryString = "SELECT * FROM ((" + posts + " " + visible(me) + ") UNION ALL ("
            + comments + " " + visible(me) + ")) a ORDER BY created_at DESC, id LIMIT \(bind: limit) OFFSET \(bind: offset)"
        return try await db.raw(q).all(decoding: Item.self)
    }
}

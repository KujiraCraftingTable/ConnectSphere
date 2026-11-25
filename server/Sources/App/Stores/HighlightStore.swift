import Vapor
import SQLKit

/// Highlights on a Hobby profile (migration 063): titled photo collections
/// that stay until each photo is removed.
enum HighlightStore {
    static let maxHighlights = 30
    static let maxItems = 100

    // MARK: - Types
    struct Item: Content {
        var id: String
        var image_url: String
        var created_at: Date
    }

    struct Highlight: Content {
        var id: String
        var title: String
        /// The chosen cover, or the first photo.
        var cover_url: String
        var items: [Item]
    }

    private struct Row: Decodable {
        let id: String
        let title: String
        let cover_url: String?
        let items: String
    }

    // MARK: - Reads
    /// Oldest first, like Facebook's row; photos in the order added.
    static func list(of user: String, on db: any SQLDatabase) async throws -> [Highlight] {
        let rows = try await db.raw("""
            SELECT h.id::text AS id, h.title, h.cover_url,
              COALESCE((SELECT json_agg(json_build_object('id', i.id, 'image_url', i.image_url, 'created_at', i.created_at)
                                        ORDER BY i.created_at)
                        FROM highlight_items i WHERE i.highlight_id = h.id), '[]')::text AS items
            FROM highlights h WHERE h.user_id = \(uuid: user)
            ORDER BY h.created_at
            """).all(decoding: Row.self)
        let decoder = JSONCoding.makeDecoder()
        return rows.compactMap { r in
            let items = (try? decoder.decode([Item].self, from: Data(r.items.utf8))) ?? []
            guard let first = items.first else { return nil }
            return Highlight(id: r.id, title: r.title, cover_url: r.cover_url ?? first.image_url, items: items)
        }
    }

    static func count(of user: String, on db: any SQLDatabase) async throws -> Int {
        struct N: Decodable { let n: Int }
        return try await db.raw("SELECT COUNT(*)::int AS n FROM highlights WHERE user_id = \(uuid: user)")
            .first(decoding: N.self)?.n ?? 0
    }

    /// Photos in it now; nil when it isn't theirs.
    static func itemCount(_ highlight: String, of user: String, on db: any SQLDatabase) async throws -> Int? {
        struct N: Decodable { let n: Int }
        return try await db.raw("""
            SELECT (SELECT COUNT(*)::int FROM highlight_items i WHERE i.highlight_id = h.id) AS n
            FROM highlights h WHERE h.id = \(uuid: highlight) AND h.user_id = \(uuid: user)
            """).first(decoding: N.self)?.n
    }

    /// The image of one of your own Hobby stories (highlights are Hobby-only).
    static func storyImage(_ story: String, of user: String, on db: any SQLDatabase) async throws -> String? {
        struct R: Decodable { let image_url: String }
        return try await db.raw("SELECT image_url FROM stories WHERE id = \(uuid: story) AND author_id = \(uuid: user) AND mode = 'hobby'")
            .first(decoding: R.self)?.image_url
    }

    // MARK: - Writes
    static func create(_ user: String, title: String, images: [String], on db: AppDatabase) async throws {
        try await db.tx { t in
            struct R: Decodable { let id: String }
            guard let h = try await t.raw("""
                INSERT INTO highlights (user_id, title) VALUES (\(uuid: user), \(bind: title)) RETURNING id::text AS id
                """).first(decoding: R.self) else { return }
            try await insertItems(h.id, images, on: t)
        }
    }

    static func addItems(_ highlight: String, images: [String], on db: any SQLDatabase) async throws {
        try await insertItems(highlight, images, on: db)
        try await db.raw("UPDATE highlights SET updated_at = now() WHERE id = \(uuid: highlight)").run()
    }

    /// One row per photo, in order (clock ticks keep them ordered).
    private static func insertItems(_ highlight: String, _ images: [String], on db: any SQLDatabase) async throws {
        for (i, image) in images.enumerated() {
            try await db.raw("""
                INSERT INTO highlight_items (highlight_id, image_url, created_at)
                VALUES (\(uuid: highlight), \(bind: image), now() + make_interval(secs => \(bind: Double(i) / 1000)))
                """).run()
        }
    }

    /// False when it isn't theirs.
    static func update(_ highlight: String, of user: String, title: String?, coverURL: String??,
                       on db: any SQLDatabase) async throws -> Bool {
        struct R: Decodable { let id: String }
        var sets: [SQLQueryString] = ["updated_at = now()"]
        if let title { sets.append("title = \(bind: title)") }
        if let coverURL { sets.append("cover_url = \(bind: coverURL)") }
        var q: SQLQueryString = "UPDATE highlights SET "
        for (i, s) in sets.enumerated() { q = q + (i == 0 ? "" : ", ") + s }
        q = q + " WHERE id = \(uuid: highlight) AND user_id = \(uuid: user) RETURNING id::text AS id"
        return try await db.raw(q).first(decoding: R.self) != nil
    }

    /// Removes one photo; the highlight goes with its last. False when it isn't theirs.
    static func removeItem(_ item: String, from highlight: String, of user: String, on db: AppDatabase) async throws -> Bool {
        var removed = false
        try await db.tx { t in
            struct R: Decodable { let id: String }
            removed = try await t.raw("""
                DELETE FROM highlight_items i USING highlights h
                WHERE i.id = \(uuid: item) AND i.highlight_id = h.id AND h.id = \(uuid: highlight) AND h.user_id = \(uuid: user)
                RETURNING i.id::text AS id
                """).first(decoding: R.self) != nil
            guard removed else { return }
            try await t.raw("""
                DELETE FROM highlights h WHERE h.id = \(uuid: highlight)
                  AND NOT EXISTS (SELECT 1 FROM highlight_items i WHERE i.highlight_id = h.id)
                """).run()
        }
        return removed
    }

    static func delete(_ highlight: String, of user: String, on db: any SQLDatabase) async throws -> Bool {
        struct R: Decodable { let id: String }
        return try await db.raw("""
            DELETE FROM highlights WHERE id = \(uuid: highlight) AND user_id = \(uuid: user) RETURNING id::text AS id
            """).first(decoding: R.self) != nil
    }
}

import Vapor
import SQLKit

/// What people look at in their feeds (migration 076): how often and how long
/// each post was on screen, fast skips, and whether they opened it. Written in
/// batches by the app; read by feed ranking.
enum ImpressionStore {
    static let sources: Set<String> = ["home", "community"]
    static let maxItems = 100
    /// One sighting longer than this is cut to it (a phone left on a post).
    static let maxViewMs = 600_000
    /// On screen for less than this = scrolled straight past.
    static let fastSkipMs = 1_000

    /// One sighting from the app: a post that was on screen for `view_ms`,
    /// or (with `opened`) one the viewer tapped into.
    struct Item: Content {
        var post_id: String
        var view_ms: Int?
        var opened: Bool?
    }

    /// A batch folded into one row per post.
    struct Totals: Equatable {
        var postID: String
        var views = 0
        var viewMs = 0
        var fastSkips = 0
        var opened = false
    }

    /// Folds a batch into per-post totals, dropping bad ids and capping times.
    static func fold(_ items: [Item]) -> [Totals] {
        var byPost: [String: Totals] = [:]
        var order: [String] = []
        for item in items {
            let id = item.post_id.lowercased()
            guard UUID(uuidString: id) != nil else { continue }
            if byPost[id] == nil { byPost[id] = Totals(postID: id); order.append(id) }
            let ms = min(max(item.view_ms ?? 0, 0), maxViewMs)
            if ms > 0 {
                byPost[id]!.views += 1
                byPost[id]!.viewMs += ms
                if ms < fastSkipMs { byPost[id]!.fastSkips += 1 }
            }
            if item.opened == true { byPost[id]!.opened = true }
        }
        return order.compactMap { byPost[$0] }
    }

    /// Adds the batch to the viewer's rows. Posts that don't exist (or aren't
    /// posted) are skipped.
    static func record(_ totals: [Totals], viewer: String, source: String, on db: any SQLDatabase) async throws {
        guard !totals.isEmpty else { return }
        try await db.raw("""
            INSERT INTO post_impressions (user_id, post_id, views, view_ms, fast_skips, opened_at, source)
            SELECT \(uuid: viewer), x.pid, x.v, x.ms, x.fs, CASE WHEN x.op THEN NOW() END, \(bind: source)
            FROM UNNEST(\(bind: totals.map(\.postID))::uuid[], \(bind: totals.map(\.views))::int[],
                        \(bind: totals.map(\.viewMs))::bigint[], \(bind: totals.map(\.fastSkips))::int[],
                        \(bind: totals.map(\.opened))::bool[]) AS x(pid, v, ms, fs, op)
            JOIN posts p ON p.id = x.pid AND p.status = 'posted'
            ON CONFLICT (user_id, post_id) DO UPDATE SET
              views        = post_impressions.views + EXCLUDED.views,
              view_ms      = post_impressions.view_ms + EXCLUDED.view_ms,
              fast_skips   = post_impressions.fast_skips + EXCLUDED.fast_skips,
              opened_at    = COALESCE(post_impressions.opened_at, EXCLUDED.opened_at),
              last_seen_at = NOW(),
              source       = EXCLUDED.source
            """).run()
    }
}

import Vapor
import SQLKit

/// Kept copies of listings (1 year) and records of confirmed sales (3 years),
/// migration 152. Law 122/2025 Art. 17.1(e) and 18.2(c), Decree 248/2026 Art.
/// 18.1(đ), and Law 19/2023 Art. 39.3(h): both outlive the listing and both
/// accounts, and the daily cleanup deletes them once `keep_until` passes.
enum ListingRecordStore {
    /// Copies the listing as it is now, unless nothing changed since the last
    /// copy. Run inside the transaction that changed it, so a copy is never of
    /// a half-made change.
    static func snapshot(listingID: String, on db: any SQLDatabase) async throws {
        try await db.raw("""
            INSERT INTO listing_archive (listing_id, post_id, seller_id, mode, snapshot, snapshot_hash, image_urls)
            SELECT l.id, p.id, p.author_id, p.mode, s.j, md5(s.j::text),
                   COALESCE((SELECT array_agg(DISTINCT x) FROM listing_items i, unnest(i.image_urls) AS x
                             WHERE i.listing_id = l.id), '{}')
            FROM listing_posts l JOIN posts p ON p.id = l.post_id
            CROSS JOIN LATERAL (SELECT listing_snapshot(l.id) AS j) s
            WHERE l.id = \(uuid: listingID) AND p.status = 'posted'
              AND md5(s.j::text) IS DISTINCT FROM (
                SELECT a.snapshot_hash FROM listing_archive a WHERE a.listing_id = l.id
                ORDER BY a.recorded_at DESC LIMIT 1)
            """).run()
    }

    /// One record per buyer per item confirmed as sold, naming both people by
    /// their usernames at the time.
    static func recordSale(listingID: String, itemID: String, buyerID: String, title: String,
                           price: Int64, quantity: Int, on db: any SQLDatabase) async throws {
        try await db.raw("""
            INSERT INTO deal_records (seller_id, buyer_id, seller_username, buyer_username, mode, listing_id, item_id,
                                      item_title, item_price, quantity)
            SELECT p.author_id, b.id, s.username, b.username, p.mode, l.id, \(uuid: itemID),
                   \(bind: title), \(bind: price), \(bind: quantity)
            FROM listing_posts l JOIN posts p ON p.id = l.post_id
            JOIN users s ON s.id = p.author_id
            JOIN users b ON b.id = \(uuid: buyerID)
            WHERE l.id = \(uuid: listingID)
            """).run()
    }

    // MARK: reading

    /// A sale as one side of it sees it.
    struct Deal: Content {
        var id: String
        /// "sold" or "bought".
        var role: String
        var item_title: String
        var item_price: Int64?
        var quantity: Int
        var other_id: String
        /// As it was when the sale was confirmed.
        var other_username: String
        var listing_id: String?
        var confirmed_at: Date
        var keep_until: Date
    }

    static let maxDeals = 500

    /// Your sales and purchases in `mode` that are still kept, newest first.
    static func deals(of userID: String, mode: String, on db: any SQLDatabase) async throws -> [Deal] {
        try await db.raw("""
            SELECT id::text AS id,
                   CASE WHEN seller_id = \(uuid: userID) THEN 'sold' ELSE 'bought' END AS role,
                   item_title, item_price, quantity::int AS quantity,
                   (CASE WHEN seller_id = \(uuid: userID) THEN buyer_id ELSE seller_id END)::text AS other_id,
                   CASE WHEN seller_id = \(uuid: userID) THEN buyer_username ELSE seller_username END AS other_username,
                   listing_id::text AS listing_id, confirmed_at, keep_until
            FROM deal_records
            WHERE (seller_id = \(uuid: userID) OR buyer_id = \(uuid: userID))
              AND mode = \(bind: mode) AND keep_until > NOW()
            ORDER BY confirmed_at DESC LIMIT \(bind: maxDeals)
            """).all(decoding: Deal.self)
    }

    /// A deal as admins see it (for a request from the authorities).
    struct AdminDeal: Content {
        var id: String
        var seller_id: String
        var buyer_id: String
        var seller_username: String
        var buyer_username: String
        var mode: String
        var listing_id: String?
        var item_id: String?
        var item_title: String
        var item_price: Int64?
        var quantity: Int
        var confirmed_at: Date
        var keep_until: Date
    }

    /// Every kept deal the user was part of, either side, any mode.
    static func adminDeals(userID: String, on db: any SQLDatabase) async throws -> [AdminDeal] {
        try await db.raw("""
            SELECT id::text AS id, seller_id::text AS seller_id, buyer_id::text AS buyer_id,
                   seller_username, buyer_username, mode, listing_id::text AS listing_id, item_id::text AS item_id,
                   item_title, item_price, quantity::int AS quantity, confirmed_at, keep_until
            FROM deal_records
            WHERE (seller_id = \(uuid: userID) OR buyer_id = \(uuid: userID)) AND keep_until > NOW()
            ORDER BY confirmed_at DESC LIMIT \(bind: maxDeals)
            """).all(decoding: AdminDeal.self)
    }

    /// What `listing_snapshot()` (migration 152) stores. `posted_at` stays the
    /// text Postgres wrote, which carries microseconds ISO8601 parsing rejects.
    struct Snapshot: Content {
        struct Item: Content {
            var id: String
            var title: String
            var price: Int64
            var condition: String
            var quantity: Int
            var sold_count: Int
            var status: String
            var image_urls: [String]
        }
        var title: String
        var description: String?
        var location: String?
        var status: String
        var reup_count: Int
        var posted_at: String
        var seller_username: String
        var items: [Item]
    }

    struct ArchivedListing: Content {
        var id: String
        var listing_id: String
        var post_id: String
        var seller_id: String
        var mode: String
        var snapshot: Snapshot
        var recorded_at: Date
        var keep_until: Date
    }

    /// Kept copies of one listing, or of every listing by one seller, newest first.
    static func archivedListings(listingID: String?, sellerID: String?, on db: any SQLDatabase) async throws -> [ArchivedListing] {
        struct Row: Decodable {
            let id: String; let listing_id: String; let post_id: String; let seller_id: String; let mode: String
            let snapshot: String; let recorded_at: Date; let keep_until: Date
        }
        var filter: SQLQueryString = "keep_until > NOW()"
        if let listingID { filter = filter + " AND listing_id = \(uuid: listingID)" }
        if let sellerID { filter = filter + " AND seller_id = \(uuid: sellerID)" }
        let rows = try await db.raw("""
            SELECT id::text AS id, listing_id::text AS listing_id, post_id::text AS post_id, seller_id::text AS seller_id,
                   mode, snapshot::text AS snapshot, recorded_at, keep_until
            FROM listing_archive WHERE \(filter)
            ORDER BY recorded_at DESC LIMIT \(bind: maxDeals)
            """).all(decoding: Row.self)
        let decoder = JSONDecoder()
        return try rows.map { r in
            ArchivedListing(id: r.id, listing_id: r.listing_id, post_id: r.post_id, seller_id: r.seller_id, mode: r.mode,
                            snapshot: try decoder.decode(Snapshot.self, from: Data(r.snapshot.utf8)),
                            recorded_at: r.recorded_at, keep_until: r.keep_until)
        }
    }

    // MARK: retention

    /// Deletes what is past `keep_until`, then the photo files that no post,
    /// edit history, live item or remaining copy still uses.
    static func purgeExpired(on db: any SQLDatabase, logger: Logger) async throws {
        try await db.raw("DELETE FROM deal_records WHERE keep_until <= NOW()").run()
        struct P: Decodable { let path: String }
        // The checks below read the table as it was before this DELETE, so the
        // archive check filters on keep_until instead of on what remains.
        let unused = try await db.raw("""
            WITH gone AS (DELETE FROM listing_archive WHERE keep_until <= NOW() RETURNING image_urls)
            SELECT DISTINCT x AS path FROM gone, unnest(gone.image_urls) AS x
            WHERE NOT EXISTS (SELECT 1 FROM listing_archive a WHERE x = ANY(a.image_urls) AND a.keep_until > NOW())
              AND NOT EXISTS (SELECT 1 FROM listing_items i WHERE x = ANY(i.image_urls))
              AND NOT EXISTS (SELECT 1 FROM posts p WHERE x = ANY(p.image_urls))
              AND NOT EXISTS (SELECT 1 FROM post_revisions r WHERE x = ANY(r.image_urls))
            """).all(decoding: P.self)
        AccountDeletionStore.deleteUploads(unused.map(\.path), logger: logger)
    }
}

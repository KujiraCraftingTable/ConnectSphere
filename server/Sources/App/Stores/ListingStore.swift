import Vapor
import SQLKit

/// Marketplace listings (migration 072): community posts with
/// post_type 'listing' and their details in listing_posts.
enum ListingStore {
    static let conditions: Set<String> = ["new", "like_new", "good", "fair"]
    static let statuses: Set<String> = ["available", "sold"]
    static let maxPrice: Int64 = 1_000_000_000_000
    static let maxTitle = 100
    static let maxLocation = 150
    static let maxAutoReply = 500

    /// The database allows 30 (migration 117); 20 is the product limit, so
    /// listings made with 30 before it still load (editing one asks to cut it down).
    static let maxItems = 20
    static let maxItemPhotos = 6
    /// How many of one item a seller can list (migration 138).
    static let maxQuantity = 999

    /// What the seller typed, checked. Price, condition and sold state live on
    /// each item (migration 117); the listing keeps a summary of them.
    struct Details {
        /// The headline; with one item, that item's title unless one was given.
        var title: String
        var items: [Item]
        var location: String?
        var autoReply: String?
        var hideFromFriends: Bool
        var latitude: Double? = nil
        var longitude: Double? = nil
        var autoReup: PostObject.ListingData.AutoReup? = nil
    }

    /// One thing for sale in a listing, as sent. `id` names an item that's
    /// already there when editing (it keeps its sold state); nil adds one.
    struct ItemIn: Content {
        var id: String?
        var title: String?
        /// Whole VND; 0 = free.
        var price: Int64?
        var condition: String?
        /// How many there are; 1 when left out.
        var quantity: Int?
        var image_urls: [String]?
        var image_alts: [String]?
    }

    struct Item {
        var id: String?
        var title: String
        var price: Int64
        var condition: String
        var quantity: Int
        var imageUrls: [String]
        var imageAlts: [String]?
    }

    /// 1–20 items, each with a title, a price, a condition and 1–6 photos.
    static func validateItems(_ raw: [ItemIn]?) throws -> [Item] {
        guard let raw, !raw.isEmpty else { throw Abort(.badRequest, reason: "Add at least one item") }
        guard raw.count <= maxItems else { throw Abort(.badRequest, reason: "A listing can have up to \(maxItems) items") }
        var seen = Set<String>()
        return try raw.enumerated().map { i, r in
            let n = i + 1
            let title = r.title?.trimmedText ?? ""
            guard !title.isEmpty, title.count <= maxTitle else {
                throw Abort(.badRequest, reason: "Item \(n): the title must be 1–\(maxTitle) characters")
            }
            guard let price = r.price, (0...maxPrice).contains(price) else {
                throw Abort(.badRequest, reason: "Item \(n): the price must be between 0 and \(maxPrice) VND")
            }
            guard let condition = r.condition, conditions.contains(condition) else {
                throw Abort(.badRequest, reason: "Item \(n): invalid condition")
            }
            let quantity = r.quantity ?? 1
            guard (1...maxQuantity).contains(quantity) else {
                throw Abort(.badRequest, reason: "Item \(n): the quantity must be 1–\(maxQuantity)")
            }
            var id: String?
            if let raw = r.id {
                guard let uuid = UUID(uuidString: raw), seen.insert(uuid.uuidString.lowercased()).inserted else {
                    throw Abort(.badRequest, reason: "Item \(n): invalid item")
                }
                id = uuid.uuidString.lowercased()
            }
            guard let urls = try MediaPath.uploaded(r.image_urls), !urls.isEmpty else {
                throw Abort(.badRequest, reason: "Item \(n): add at least one photo")
            }
            guard urls.count <= maxItemPhotos else {
                throw Abort(.badRequest, reason: "Item \(n): up to \(maxItemPhotos) photos")
            }
            return Item(id: id, title: title, price: price, condition: condition, quantity: quantity,
                        imageUrls: urls, imageAlts: PostStore.cleanAlts(r.image_alts, count: urls.count))
        }
    }

    // MARK: auto re-up (migration 095)

    static let autoReupDays = [1, 3, 7]
    static let autoReupHours = [9, 12, 15, 18, 21, 24]
    /// The schedule's clock, whatever the seller's phone says.
    static let vietnam: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Ho_Chi_Minh")!
        return c
    }()

    static func validateAutoReup(_ a: PostObject.ListingData.AutoReup?) throws {
        guard let a else { return }
        guard autoReupDays.contains(a.every_days) else { throw Abort(.badRequest, reason: "Auto re-up must be every 1, 3 or 7 days") }
        guard autoReupHours.contains(a.hour) else { throw Abort(.badRequest, reason: "Auto re-up hour must be 9, 12, 15, 18, 21 or 24") }
    }

    /// `days` calendar days on from the day of `from` (Vietnam time), at
    /// `hour`:00, 24 is that day's following midnight.
    static func nextAutoReup(from: Date, days: Int, hour: Int, calendar: Calendar = vietnam) -> Date {
        let day = calendar.startOfDay(for: from)
        let target = calendar.date(byAdding: .day, value: days, to: day)!
        return calendar.date(byAdding: .hour, value: hour, to: target)!
    }

    /// A slot that's already past moves on by whole intervals, so a missed run
    /// never fires twice.
    static func advanceAutoReup(_ slot: Date, days: Int, after now: Date, calendar: Calendar = vietnam) -> Date {
        var next = slot
        while next <= now { next = calendar.date(byAdding: .day, value: days, to: next)! }
        return next
    }

    /// A place picked on the map: both coordinates or neither, in range.
    static func coordinates(_ lat: Double?, _ lng: Double?) throws -> (Double, Double)? {
        switch (lat, lng) {
        case (nil, nil): return nil
        case let (lat?, lng?):
            guard (-90...90).contains(lat), (-180...180).contains(lng) else {
                throw Abort(.badRequest, reason: "Invalid map location")
            }
            return (lat, lng)
        default: throw Abort(.badRequest, reason: "A map location needs both latitude and longitude")
        }
    }

    static func validate(_ d: PostsController.CreateBody.ListingDataIn?) throws -> Details {
        guard let d else { throw Abort(.badRequest, reason: "Listing details are required") }
        let items = try validateItems(d.items)
        var title = d.title?.trimmedText ?? ""
        if title.isEmpty, items.count == 1 { title = items[0].title }
        guard !title.isEmpty else { throw Abort(.badRequest, reason: "Give the listing a title") }
        guard title.count <= maxTitle else { throw Abort(.badRequest, reason: "Listing title must be at most \(maxTitle) characters") }
        let location = d.location?.trimmedText.nilIfEmpty
        if let location, location.count > maxLocation {
            throw Abort(.badRequest, reason: "Location must be at most \(maxLocation) characters")
        }
        let autoReply = d.autoReply?.trimmedText.nilIfEmpty
        if let autoReply, autoReply.count > maxAutoReply {
            throw Abort(.badRequest, reason: "Auto-reply must be at most \(maxAutoReply) characters")
        }
        let point = try coordinates(d.latitude, d.longitude)
        try validateAutoReup(d.autoReup)
        return Details(title: title, items: items, location: location,
                       autoReply: autoReply, hideFromFriends: d.hideFromFriends ?? false,
                       latitude: point?.0, longitude: point?.1, autoReup: d.autoReup)
    }

    /// Returns the listing's id. Its price, condition and status start from the
    /// items and `syncSummary` keeps them (and the post's photos) in step.
    static func create(postID: String, _ d: Details, on db: any SQLDatabase) async throws -> String {
        struct R: Decodable { let id: String }
        let id = try await db.raw("""
            INSERT INTO listing_posts (post_id, title, price, condition, location, auto_reply, hide_from_friends,
                                       latitude, longitude, auto_reup_days, auto_reup_hour, next_auto_reup_at)
            VALUES (\(uuid: postID), \(bind: d.title), \(bind: d.items.map(\.price).min() ?? 0), \(bind: d.items.first?.condition),
                    \(bind: d.location), \(bind: d.autoReply), \(bind: d.hideFromFriends),
                    \(bind: d.latitude), \(bind: d.longitude),
                    \(bind: d.autoReup?.every_days), \(bind: d.autoReup?.hour),
                    \(bind: d.autoReup.map { nextAutoReup(from: Date(), days: $0.every_days, hour: $0.hour) }))
            RETURNING id::text AS id
            """).first(decoding: R.self)!.id
        for (i, item) in d.items.enumerated() { try await insertItem(item, at: i, listingID: id, on: db) }
        try await syncSummary(listingID: id, on: db)
        return id
    }

    // MARK: items (migration 117)

    static func insertItem(_ item: Item, at position: Int, listingID: String, on db: any SQLDatabase) async throws {
        try await db.raw("""
            INSERT INTO listing_items (listing_id, position, title, price, condition, quantity, image_urls, image_alts)
            VALUES (\(uuid: listingID), \(bind: position), \(bind: item.title), \(bind: item.price),
                    \(bind: item.condition), \(bind: item.quantity), \(bind: item.imageUrls), \(bind: item.imageAlts))
            """).run()
    }

    /// The seller's edited item list, replacing the old one: items sent with
    /// their id are updated (and keep how many have sold), new ones are added
    /// and any left out are removed. Run inside a transaction.
    static func replaceItems(listingID: String, _ items: [Item], on db: any SQLDatabase) async throws {
        struct R: Decodable { let id: String; let quantity: Int; let taken: Int }
        let existing = Dictionary(uniqueKeysWithValues: try await db.raw("""
            SELECT id::text AS id, quantity,
              sold_count + COALESCE((SELECT SUM(d.quantity) FROM listing_item_deposits d WHERE d.item_id = li.id), 0)::int AS taken
            FROM listing_items li WHERE listing_id = \(uuid: listingID) FOR UPDATE
            """).all(decoding: R.self).map { ($0.id, $0) })
        let kept = items.compactMap(\.id)
        guard kept.allSatisfy({ existing[$0] != nil }) else { throw Abort(.badRequest, reason: "That item isn't in this listing") }
        for (i, item) in items.enumerated() {
            guard let id = item.id, let old = existing[id] else { continue }
            // Raising it would make room for more sales, and more review cards,
            // on a listing buyers already trust: selling more is a new listing.
            guard item.quantity <= old.quantity else {
                throw Abort(.badRequest, reason: "Item \(i + 1): the quantity can't go up. Post a new listing to sell more")
            }
            guard item.quantity >= old.taken else {
                throw Abort(.badRequest, reason: "Item \(i + 1): \(old.taken) are sold or on deposit, so the quantity can't be less")
            }
        }
        try await db.raw("""
            DELETE FROM listing_items WHERE listing_id = \(uuid: listingID) AND NOT (id = ANY(\(bind: kept)::uuid[]))
            """).run()
        for (i, item) in items.enumerated() {
            if let id = item.id {
                try await db.raw("""
                    UPDATE listing_items SET position = \(bind: i), title = \(bind: item.title), price = \(bind: item.price),
                      condition = \(bind: item.condition), image_urls = \(bind: item.imageUrls),
                      image_alts = \(bind: item.imageAlts), quantity = \(bind: item.quantity),
                      status = CASE WHEN sold_count >= \(bind: item.quantity) THEN 'sold' ELSE 'available' END,
                      updated_at = NOW()
                    WHERE id = \(uuid: id) AND listing_id = \(uuid: listingID)
                    """).run()
            } else {
                try await insertItem(item, at: i, listingID: listingID, on: db)
            }
        }
    }

    /// Sets the buyer's deposit on one item: `quantity` units held for them
    /// (0 clears it). At most their current deposit plus the free units.
    static func setDeposit(listingID: String, itemID: String, buyer: String, conversationID: String,
                           quantity: Int, on db: AppDatabase) async throws {
        guard (0...maxQuantity).contains(quantity) else { throw Abort(.badRequest, reason: "Invalid deposit") }
        try await db.tx { t in
            struct R: Decodable { let quantity: Int; let sold_count: Int; let held: Int; let mine: Int }
            guard let row = try await t.raw("""
                SELECT li.quantity, li.sold_count,
                  COALESCE((SELECT SUM(d.quantity) FROM listing_item_deposits d WHERE d.item_id = li.id), 0)::int AS held,
                  COALESCE((SELECT d.quantity FROM listing_item_deposits d
                            WHERE d.item_id = li.id AND d.buyer_id = \(uuid: buyer)), 0)::int AS mine
                FROM listing_items li WHERE li.id = \(uuid: itemID) AND li.listing_id = \(uuid: listingID) FOR UPDATE
                """).first(decoding: R.self) else { throw Abort(.notFound, reason: "Item not found") }
            let most = row.mine + (row.quantity - row.sold_count - row.held)
            guard quantity <= most else {
                throw Abort(.badRequest, reason: "Only \(most) can be on deposit for this buyer")
            }
            if quantity == 0 {
                try await t.raw("""
                    DELETE FROM listing_item_deposits WHERE item_id = \(uuid: itemID) AND buyer_id = \(uuid: buyer)
                    """).run()
            } else {
                try await t.raw("""
                    INSERT INTO listing_item_deposits (item_id, buyer_id, conversation_id, quantity)
                    VALUES (\(uuid: itemID), \(uuid: buyer), \(uuid: conversationID), \(bind: quantity))
                    ON CONFLICT (item_id, buyer_id) DO UPDATE SET quantity = EXCLUDED.quantity,
                      conversation_id = EXCLUDED.conversation_id, updated_at = NOW()
                    """).run()
            }
        }
    }

    /// What one confirmed deposit turned into: the card's contents.
    struct ConfirmedSale: Decodable {
        let item_id: String
        let buyer_id: String
        let conversation_id: String
        let quantity: Int
        let title: String
        let price: Int64
        let image: String
    }

    /// Turns each buyer's deposit on one item (or on every item of the listing
    /// when `itemID` is nil) into sold units, all or nothing: a buyer without a
    /// deposit fails the whole request. Sales are final.
    static func confirmDeposits(listingID: String, itemID: String?, buyers: [String],
                                on db: AppDatabase) async throws -> [ConfirmedSale] {
        var confirmed: [ConfirmedSale] = []
        try await db.tx { t in
            let itemFilter: SQLQueryString = itemID.map { " AND li.id = \(uuid: $0)" } ?? ""
            let sales = try await t.raw("""
                SELECT li.id::text AS item_id, d.buyer_id::text AS buyer_id, d.conversation_id::text AS conversation_id,
                  d.quantity::int AS quantity, li.title, li.price, li.image_urls[1] AS image
                FROM listing_item_deposits d JOIN listing_items li ON li.id = d.item_id
                WHERE li.listing_id = \(uuid: listingID) AND d.buyer_id = ANY(\(bind: buyers)::uuid[])
                """ + itemFilter + " ORDER BY li.position FOR UPDATE OF li, d").all(decoding: ConfirmedSale.self)
            guard Set(sales.map(\.buyer_id)) == Set(buyers) else {
                throw Abort(.badRequest, reason: "No deposit from this buyer")
            }
            // Several buyers can hold the same item, so add up per item first.
            var soldPerItem: [String: Int] = [:]
            for sale in sales { soldPerItem[sale.item_id, default: 0] += sale.quantity }
            for (item, quantity) in soldPerItem {
                try await t.raw("""
                    UPDATE listing_items SET sold_count = sold_count + \(bind: quantity),
                      status = CASE WHEN sold_count + \(bind: quantity) >= quantity THEN 'sold' ELSE 'available' END,
                      updated_at = NOW()
                    WHERE id = \(uuid: item)
                    """).run()
            }
            for sale in sales {
                try await t.raw("""
                    DELETE FROM listing_item_deposits WHERE item_id = \(uuid: sale.item_id) AND buyer_id = \(uuid: sale.buyer_id)
                    """).run()
            }
            try await syncSummary(listingID: listingID, on: t)
            confirmed = sales
        }
        return confirmed
    }

    /// Rewrites what the rest of the app reads off the listing from its items:
    /// the lowest price still for sale, 'sold' once every item is (which, like
    /// marking a listing sold always has, ends auto re-up for good), the first
    /// item's condition, and the post's photos: each item's first photo, or
    /// all of them when there's only one item (so it looks as it always did).
    /// Sold items' covers go last: a "SOLD" first photo reads as "all sold".
    /// The app orders items the same way (`ListingData.displayItems`).
    static func syncSummary(listingID: String, on db: any SQLDatabase) async throws {
        try await db.raw("""
            WITH s AS (
              SELECT COUNT(*) AS n,
                     COALESCE(MIN(price) FILTER (WHERE status = 'available'), MIN(price)) AS price,
                     CASE WHEN bool_and(status = 'sold') THEN 'sold' ELSE 'available' END AS status,
                     (array_agg(condition ORDER BY position))[1] AS condition,
                     array_agg(image_urls[1] ORDER BY (status = 'sold'), position) AS covers,
                     array_agg(COALESCE(image_alts[1], '') ORDER BY (status = 'sold'), position) AS alts
              FROM listing_items WHERE listing_id = \(uuid: listingID)
            ), l AS (
              UPDATE listing_posts lp SET price = s.price, status = s.status, condition = s.condition, updated_at = NOW(),
                auto_reup_days = CASE WHEN s.status = 'sold' THEN NULL ELSE lp.auto_reup_days END,
                auto_reup_hour = CASE WHEN s.status = 'sold' THEN NULL ELSE lp.auto_reup_hour END,
                next_auto_reup_at = CASE WHEN s.status = 'sold' THEN NULL ELSE lp.next_auto_reup_at END
              FROM s WHERE lp.id = \(uuid: listingID) AND s.price IS NOT NULL
              RETURNING lp.post_id
            )
            UPDATE posts p SET
              image_urls = CASE WHEN s.n = 1
                THEN (SELECT image_urls FROM listing_items WHERE listing_id = \(uuid: listingID)) ELSE s.covers END,
              image_alts = CASE WHEN s.n = 1
                THEN (SELECT image_alts FROM listing_items WHERE listing_id = \(uuid: listingID))
                WHEN array_to_string(s.alts, '') = '' THEN NULL ELSE s.alts END
            FROM s, l WHERE p.id = l.post_id
            """).run()
    }

    // MARK: communities it's listed in (migration 073)

    static let maxCommunities = 5

    /// The communities to also list in: at most 5, no repeats, valid ids.
    static func communityIDs(_ raw: [String]?) throws -> [String] {
        var seen = Set<String>()
        var ids: [String] = []
        for r in raw ?? [] {
            guard let uuid = UUID(uuidString: r) else { throw Abort(.badRequest, reason: "Invalid community") }
            let id = uuid.uuidString.lowercased()
            if seen.insert(id).inserted { ids.append(id) }
        }
        guard ids.count <= maxCommunities else {
            throw Abort(.badRequest, reason: "A listing can be in up to \(maxCommunities) communities")
        }
        return ids
    }

    struct Link { var communityID: String; var pending: Bool }

    /// Each community must be one the seller belongs to, of the listing's
    /// mode (work communities for Work, the rest for Hobby). A community that
    /// approves posts gets the listing pending its admins' approval.
    static func links(_ ids: [String], seller: String, mode: String, on db: any SQLDatabase) async throws -> [Link] {
        guard !ids.isEmpty else { return [] }
        struct R: Decodable { let id: String; let type: String; let member: Bool }
        let rows = try await db.raw("""
            SELECT c.id::text AS id, c.type,
              EXISTS (SELECT 1 FROM community_members m WHERE m.community_id = c.id AND m.user_id = \(uuid: seller)) AS member
            FROM communities c WHERE c.id = ANY(\(bind: ids)::uuid[])
            """).all(decoding: R.self)
        guard rows.count == ids.count, rows.allSatisfy(\.member) else {
            throw Abort(.forbidden, reason: "You can only list in communities you've joined")
        }
        guard rows.allSatisfy({ ($0.type == "work" ? "work" : "hobby") == mode }) else {
            throw Abort(.badRequest, reason: "These communities don't match this listing's mode")
        }
        var out: [Link] = []
        for id in ids {
            out.append(Link(communityID: id, pending: try await CommunityStore.needsApproval(id, author: seller, on: db)))
        }
        return out
    }

    static func link(listingID: String, _ links: [Link], on db: any SQLDatabase) async throws {
        for l in links {
            try await db.raw("""
                INSERT INTO listing_communities (listing_id, community_id, status)
                VALUES (\(uuid: listingID), \(uuid: l.communityID), \(bind: l.pending ? "pending" : "posted"))
                ON CONFLICT DO NOTHING
                """).run()
        }
    }

    /// Edit listing: the listing is now in exactly these communities. A removed
    /// one loses the post (or its waiting request); an added one is checked and
    /// linked as at creation, waiting where the admins approve posts. Ticking a
    /// community that declined it asks its admins again. Returns the communities
    /// it just went live in, to notify.
    static func setCommunities(listingID: String, _ raw: [String], seller: String, on db: AppDatabase) async throws -> [String] {
        let ids = try communityIDs(raw)
        let sql = db.sql()
        struct M: Decodable { let mode: String }
        guard let mode = try await sql.raw("""
            SELECT p.mode FROM posts p JOIN listing_posts l ON l.post_id = p.id WHERE l.id = \(uuid: listingID)
            """).first(decoding: M.self)?.mode else { throw Abort(.notFound, reason: "Listing not found") }
        struct Current: Decodable { let community_id: String; let status: String }
        let current = try await sql.raw("""
            SELECT community_id::text AS community_id, status FROM listing_communities WHERE listing_id = \(uuid: listingID)
            """).all(decoding: Current.self)
        let active = Set(current.filter { $0.status != "declined" }.map(\.community_id))
        let removed = Array(active.subtracting(ids))
        let added = try await links(ids.filter { !active.contains($0) }, seller: seller, mode: mode, on: sql)
        try await db.tx { t in
            if !removed.isEmpty {
                try await t.raw("""
                    DELETE FROM listing_communities
                    WHERE listing_id = \(uuid: listingID) AND community_id = ANY(\(bind: removed)::uuid[])
                    """).run()
            }
            for l in added {
                try await t.raw("""
                    INSERT INTO listing_communities (listing_id, community_id, status)
                    VALUES (\(uuid: listingID), \(uuid: l.communityID), \(bind: l.pending ? "pending" : "posted"))
                    ON CONFLICT (listing_id, community_id) DO UPDATE
                      SET status = EXCLUDED.status, created_at = NOW(), reviewed_by = NULL, reviewed_at = NULL
                    """).run()
            }
        }
        return added.filter { !$0.pending }.map(\.communityID)
    }

    /// SQL: post `p` is a listing shown in community `communityID` (its link
    /// there has `status`).
    static func listedInClause(_ communityID: String, status: String = "posted") -> SQLQueryString {
        """
        (p.post_type = 'listing' AND EXISTS (SELECT 1 FROM listing_posts li
          JOIN listing_communities lci ON lci.listing_id = li.id
          WHERE li.post_id = p.id AND lci.community_id = \(uuid: communityID) AND lci.status = \(bind: status)))
        """
    }

    /// Listed (and live) in any of these communities.
    static func listedInAnyClause(_ communityIDs: [String]) -> SQLQueryString {
        """
        EXISTS (SELECT 1 FROM listing_posts lia
          JOIN listing_communities lcia ON lcia.listing_id = lia.id
          WHERE lia.post_id = p.id AND lcia.community_id = ANY(\(bind: communityIDs)::uuid[]) AND lcia.status = 'posted')
        """
    }

    /// When a listing showed up in this community: approval restarts its clock
    /// there (it's new to the community), while Marketplace and other
    /// communities keep the listing's own time. A re-up after approval is newer still.
    static func communityShownAt(_ communityID: String) -> SQLQueryString {
        """
        GREATEST(p.created_at, COALESCE((SELECT lcs.reviewed_at FROM listing_posts lps
          JOIN listing_communities lcs ON lcs.listing_id = lps.id
          WHERE lps.post_id = p.id AND lcs.community_id = \(uuid: communityID) AND lcs.status = 'posted'), p.created_at))
        """
    }

    /// `posts` as this community shows them: each approved listing dated by
    /// `communityShownAt`.
    static func datedForCommunity(_ posts: [PostObject], _ communityID: String, on db: any SQLDatabase) async throws -> [PostObject] {
        let ids = posts.filter { $0.post_type == "listing" }.map(\.id)
        guard !ids.isEmpty else { return posts }
        struct R: Decodable { let post_id: String; let reviewed_at: Date }
        let rows = try await db.raw("""
            SELECT lp.post_id::text AS post_id, lc.reviewed_at FROM listing_posts lp
            JOIN listing_communities lc ON lc.listing_id = lp.id
            WHERE lp.post_id = ANY(\(bind: ids)::uuid[]) AND lc.community_id = \(uuid: communityID)
              AND lc.status = 'posted' AND lc.reviewed_at IS NOT NULL
            """).all(decoding: R.self)
        let approved = Dictionary(rows.map { ($0.post_id, $0.reviewed_at) }, uniquingKeysWith: max)
        return posts.map { post in
            var post = post
            if let at = approved[post.id], at > post.created_at { post.created_at = at }
            return post
        }
    }

    /// An admin's decision on a listing waiting in their community. nil when
    /// it isn't waiting there.
    static func reviewLink(postID: String, in communityID: String, approve: Bool, reviewer: String,
                           on db: any SQLDatabase) async throws -> CommunityStore.Reviewed? {
        try await db.raw("""
            UPDATE listing_communities lc SET status = \(bind: approve ? "posted" : "declined"),
              reviewed_by = \(uuid: reviewer), reviewed_at = NOW()
            FROM listing_posts l JOIN posts p ON p.id = l.post_id
            WHERE lc.listing_id = l.id AND l.post_id = \(uuid: postID)
              AND lc.community_id = \(uuid: communityID) AND lc.status = 'pending'
            RETURNING p.author_id::text AS author_id
            """).first(decoding: CommunityStore.Reviewed.self)
    }

    // MARK: visibility

    /// A listing marked "hide from friends" is invisible to the seller's
    /// connections in the listing's mode. Every query that can return a
    /// listing post (aliased `p`) adds this.
    static func notHiddenFromFriendClause(_ v: String) -> SQLQueryString {
        """
        (p.post_type <> 'listing' OR p.author_id = \(uuid: v) OR NOT EXISTS (
          SELECT 1 FROM listing_posts lh WHERE lh.post_id = p.id AND lh.hide_from_friends
            AND EXISTS (SELECT 1 FROM connections lc WHERE lc.status = 'accepted' AND lc.mode = p.mode
              AND ((lc.requester_id = p.author_id AND lc.addressee_id = \(uuid: v))
                OR (lc.addressee_id = p.author_id AND lc.requester_id = \(uuid: v))))))
        """
    }

    /// The `listing_data` column for posts aliased `p` (see PostStore.typeDataColumns).
    /// The auto-reply text is the seller's own setting, so only they get it back.
    static func dataColumn(_ v: String) -> SQLQueryString {
        """
          (CASE WHEN p.post_type = 'listing' THEN (
            SELECT json_build_object('id', lp.id, 'title', lp.title, 'price', lp.price, 'condition', lp.condition,
              'location', lp.location, 'latitude', lp.latitude, 'longitude', lp.longitude,
              'status', lp.status, 'reup_count', lp.reup_count, 'hide_from_friends', lp.hide_from_friends,
              'auto_reup', CASE WHEN p.author_id = \(uuid: v) AND lp.auto_reup_days IS NOT NULL
                  THEN json_build_object('every_days', lp.auto_reup_days, 'hour', lp.auto_reup_hour) END,
              'next_auto_reup_at', CASE WHEN p.author_id = \(uuid: v) THEN lp.next_auto_reup_at END,
              'next_reup_at', CASE WHEN p.author_id = \(uuid: v)
                  AND p.created_at > NOW() - make_interval(secs => \(unsafeRaw: String(Int(reupCooldown))))
                  THEN p.created_at + make_interval(secs => \(unsafeRaw: String(Int(reupCooldown)))) END,
              'has_auto_reply', lp.auto_reply IS NOT NULL,
              'auto_reply', CASE WHEN p.author_id = \(uuid: v) THEN lp.auto_reply END,
              'items', COALESCE((SELECT json_agg(json_build_object('id', li.id, 'title', li.title, 'price', li.price,
                  'condition', li.condition, 'status', li.status, 'image_urls', li.image_urls,
                  'quantity', li.quantity, 'sold_count', li.sold_count,
                  'on_hold', COALESCE((SELECT SUM(dh.quantity) FROM listing_item_deposits dh WHERE dh.item_id = li.id), 0),
                  -- Who the deposits are from is the seller's business only.
                  'deposits', CASE WHEN p.author_id = \(uuid: v) THEN COALESCE((SELECT json_agg(json_build_object(
                      'buyer_id', dd.buyer_id, 'conversation_id', dd.conversation_id, 'quantity', dd.quantity)
                      ORDER BY dd.updated_at) FROM listing_item_deposits dd WHERE dd.item_id = li.id), '[]') END,
                  'image_alts', li.image_alts,
                  'ask_again_at', (SELECT a.asked_at + make_interval(secs => \(bind: askCooldown)) FROM listing_item_asks a
                    WHERE a.item_id = li.id AND a.buyer_id = \(uuid: v)
                      AND a.asked_at > NOW() - make_interval(secs => \(bind: askCooldown)))) ORDER BY li.position)
                FROM listing_items li WHERE li.listing_id = lp.id), '[]'),
              'communities', COALESCE((SELECT json_agg(json_build_object('id', lc.community_id, 'name', lcc.name,
                  'icon_emoji', lcc.icon_emoji, 'pending', lc.status = 'pending') ORDER BY lc.created_at)
                FROM listing_communities lc JOIN communities lcc ON lcc.id = lc.community_id
                -- The seller also sees the ones waiting for approval (Edit listing ticks them).
                WHERE lc.listing_id = lp.id
                  AND (lc.status = 'posted' OR (lc.status = 'pending' AND p.author_id = \(uuid: v)))), '[]'))
            FROM listing_posts lp WHERE lp.post_id = p.id
          ) ELSE NULL END)::text AS listing_data,
        """
    }

    // MARK: marketplace

    /// Every available listing in `mode` the viewer may see, newest first,
    /// or only those listed in `communityID`. The feed's visibility rules
    /// (privacy and hide-from-friends, blocks, hidden, muted words) apply.
    /// `inCommunities` / `outsideCommunities` split a seller's page into the
    /// listings in the community you came from and the rest.
    static func marketplace(viewer: String, mode: String, query: String?, communityID: String?, sellerID: String? = nil,
                            inCommunities: [String]? = nil, outsideCommunities: [String]? = nil,
                            limit: Int, offset: Int, on db: any SQLDatabase) async throws -> [PostObject] {
        // A seller's own page lists their sold items too; the Marketplace doesn't.
        let status: SQLQueryString = sellerID == nil ? " AND lm.status = 'available'" : ""
        var q = PostStore.buildPostSelect(viewer)
            + " JOIN listing_posts lm ON lm.post_id = p.id"
            + " WHERE p.status = 'posted' AND p.post_type = 'listing'" + status
            + " AND p.mode = \(bind: mode)"
            + " AND " + PostStore.privacyClause(viewer) + " AND " + PostStore.notBlockedClause(viewer)
            + " AND " + PostStore.notHiddenClause(viewer) + " AND " + PostStore.notMutedWordsClause(viewer)
        if let communityID { q = q + " AND " + listedInClause(communityID) }
        if let sellerID { q = q + " AND p.author_id = \(uuid: sellerID)" }
        if let inCommunities { q = q + " AND " + listedInAnyClause(inCommunities) }
        if let outsideCommunities, !outsideCommunities.isEmpty { q = q + " AND NOT " + listedInAnyClause(outsideCommunities) }
        if let query {
            let like = "%" + UserStore.escapeLike(query) + "%"
            q = q + " AND (lm.title ILIKE \(bind: like) OR p.content ILIKE \(bind: like)"
                + " OR EXISTS (SELECT 1 FROM listing_items lq WHERE lq.listing_id = lm.id AND lq.title ILIKE \(bind: like)))"
        }
        q = q + " GROUP BY p.id, u.id, lm.status ORDER BY (lm.status = 'sold'), p.created_at DESC"
            + " LIMIT \(bind: limit) OFFSET \(bind: offset)"
        return try await db.raw(q).all(decoding: PostStore.PostRow.self).map(PostStore.map)
    }

    // MARK: seller edits

    struct Owner: Decodable {
        let post_id: String
        let author_id: String
    }

    static func owner(listingID: String, on db: any SQLDatabase) async throws -> Owner? {
        try await db.raw("""
            SELECT p.id::text AS post_id, p.author_id::text AS author_id
            FROM listing_posts l JOIN posts p ON p.id = l.post_id
            WHERE l.id = \(uuid: listingID) AND p.status <> 'deleted'
            """).first(decoding: Owner.self)
    }

    struct Patch: Content {
        /// The headline.
        var title: String?
        /// The description (the post's text), written however the seller likes.
        var content: String?
        /// "markdown" when the description was written with Markdown.
        var content_format: String?
        var location: String?
        var auto_reply: String?
        var hide_from_friends: Bool?
        /// No longer accepted: a sale is recorded from a buyer's deposit (migration 139).
        var status: String?
        /// Both together; `clear_coordinates` removes the map location.
        var latitude: Double?
        var longitude: Double?
        var clear_coordinates: Bool?
        /// The whole item list, replacing the old one (see `replaceItems`).
        var items: [ItemIn]?
        /// Set or change the auto re-up schedule, or `clear_auto_reup` to stop it.
        var auto_reup: PostObject.ListingData.AutoReup?
        var clear_auto_reup: Bool?
        /// Every community it should be listed in (0–5); see `setCommunities`.
        /// Applied by the controller, which knows the seller.
        var community_ids: [String]?
    }

    /// Applies only the fields sent; an empty location or auto-reply clears it.
    /// True when the description changed (the caller re-translates and re-scans it).
    @discardableResult
    static func update(listingID: String, _ p: Patch, on db: AppDatabase) async throws -> Bool {
        var sets: [SQLQueryString] = []
        if let t = p.title {
            let title = t.trimmedText
            guard !title.isEmpty, title.count <= maxTitle else { throw Abort(.badRequest, reason: "Listing title must be 1–\(maxTitle) characters") }
            sets.append("title = \(bind: title)")
        }
        if let l = p.location {
            let location = l.trimmedText.nilIfEmpty
            if let location, location.count > maxLocation { throw Abort(.badRequest, reason: "Location must be at most \(maxLocation) characters") }
            sets.append("location = \(bind: location)")
        }
        if let a = p.auto_reply {
            let reply = a.trimmedText.nilIfEmpty
            if let reply, reply.count > maxAutoReply { throw Abort(.badRequest, reason: "Auto-reply must be at most \(maxAutoReply) characters") }
            sets.append("auto_reply = \(bind: reply)")
        }
        if let h = p.hide_from_friends { sets.append("hide_from_friends = \(bind: h)") }
        if p.clear_coordinates == true {
            sets.append("latitude = NULL")
            sets.append("longitude = NULL")
        } else if let point = try coordinates(p.latitude, p.longitude) {
            sets.append("latitude = \(bind: point.0)")
            sets.append("longitude = \(bind: point.1)")
        }
        // Sales are final and each one is tied to a buyer (migration 139).
        if p.status != nil { throw Abort(.badRequest, reason: "Record a sale from a buyer's deposit instead") }
        try validateAutoReup(p.auto_reup)
        // Sold cancels auto re-up for good (syncSummary); otherwise the patch sets or clears it.
        if p.clear_auto_reup == true {
            sets.append("auto_reup_days = NULL")
            sets.append("auto_reup_hour = NULL")
            sets.append("next_auto_reup_at = NULL")
        } else if let a = p.auto_reup {
            sets.append("auto_reup_days = \(bind: a.every_days)")
            sets.append("auto_reup_hour = \(bind: a.hour)")
            sets.append("next_auto_reup_at = \(bind: nextAutoReup(from: Date(), days: a.every_days, hour: a.hour))")
        }
        let items = try p.items.map(validateItems)
        let content = p.content?.trimmedText
        if let content, content.count > 2000 { throw Abort(.badRequest, reason: "Description must be at most 2000 characters") }
        let format = p.content_format.flatMap { PostStore.contentFormats.contains($0) ? $0 : nil }
        guard !sets.isEmpty || items != nil || content != nil || p.community_ids != nil else {
            throw Abort(.badRequest, reason: "Nothing to update")
        }
        var contentChanged = false
        if let content { contentChanged = try await descriptionDiffers(listingID: listingID, content, on: db.sql()) }
        let changed = contentChanged
        var q: SQLQueryString = "UPDATE listing_posts SET updated_at = NOW()"
        for s in sets { q = q + ", " + s }
        let listingUpdate: SQLQueryString? = sets.isEmpty ? nil : q + " WHERE id = \(uuid: listingID)"
        try await db.tx { t in
            if let listingUpdate { try await t.raw(listingUpdate).run() }
            if let items { try await replaceItems(listingID: listingID, items, on: t) }
            if items != nil { try await syncSummary(listingID: listingID, on: t) }
            if changed, let content {
                // Keep the version being replaced, like any post edit (post_revisions).
                try await t.raw("""
                    INSERT INTO post_revisions (post_id, content, content_format, image_urls, image_alts, article_title, link_url)
                    SELECT id, content, content_format, image_urls, image_alts, article_title, link_url
                    FROM posts WHERE id = (SELECT post_id FROM listing_posts WHERE id = \(uuid: listingID))
                    """).run()
                try await t.raw("""
                    UPDATE posts SET content = \(bind: content), content_format = COALESCE(\(bind: format), content_format),
                      edited_at = NOW(), updated_at = NOW()
                    WHERE id = (SELECT post_id FROM listing_posts WHERE id = \(uuid: listingID))
                    """).run()
            }
        }
        return changed
    }

    private static func descriptionDiffers(listingID: String, _ content: String, on db: any SQLDatabase) async throws -> Bool {
        struct R: Decodable { let content: String? }
        let row = try await db.raw("""
            SELECT p.content FROM posts p JOIN listing_posts l ON l.post_id = p.id WHERE l.id = \(uuid: listingID)
            """).first(decoding: R.self)
        return (row?.content ?? "") != content
    }

    // MARK: asking about an item (migration 119)

    /// How often one buyer may ask about one item: keeps "Ask about this" from
    /// flooding the seller's chat.
    static let askCooldown: TimeInterval = 20 * 60

    /// Whole minutes left (rounded up, at least 1) before a buyer who last asked
    /// at `lastAsked` may ask again.
    static func askWaitMinutes(lastAsked: Date, now: Date = Date()) -> Int {
        let left = askCooldown - now.timeIntervalSince(lastAsked)
        return max(1, Int((left / 60).rounded(.up)))
    }

    /// Records that `buyer` asks about the item now. Refuses a sold or missing
    /// item, and a second ask within `askCooldown` (with how long to wait).
    static func claimItemAsk(listingID: String, itemID: String, buyer: String, on db: any SQLDatabase) async throws {
        struct Item: Decodable { let status: String }
        guard let item = try await db.raw("""
            SELECT status FROM listing_items WHERE id = \(uuid: itemID) AND listing_id = \(uuid: listingID)
            """).first(decoding: Item.self) else { throw Abort(.notFound, reason: "Item not found") }
        guard item.status == "available" else { throw Abort(.conflict, reason: "This item has been sold") }
        // One statement, so two quick taps can't both get through.
        let claimed = try await db.raw("""
            INSERT INTO listing_item_asks (item_id, buyer_id) VALUES (\(uuid: itemID), \(uuid: buyer))
            ON CONFLICT (item_id, buyer_id) DO UPDATE SET asked_at = NOW()
            WHERE listing_item_asks.asked_at <= NOW() - make_interval(secs => \(bind: askCooldown))
            RETURNING 1 AS one
            """).all()
        guard claimed.isEmpty else { return }
        struct Last: Decodable { let asked_at: Date }
        let last = try await db.raw("""
            SELECT asked_at FROM listing_item_asks WHERE item_id = \(uuid: itemID) AND buyer_id = \(uuid: buyer)
            """).first(decoding: Last.self)
        let minutes = askWaitMinutes(lastAsked: last?.asked_at ?? Date())
        throw Abort(.tooManyRequests, reason: "You can ask about this item again in \(minutes) minutes")
    }

    // MARK: re-up (migration 093)

    /// A seller re-ups by hand at most once in this long. The current post's
    /// `created_at` is when it was last listed, since a re-up makes a new post.
    static let reupCooldown: TimeInterval = 8 * 3600

    /// "3h 20m" left before the next re-up, or nil when it's allowed now.
    static func reupWait(lastListed: Date, now: Date = Date()) -> String? {
        let left = reupCooldown - now.timeIntervalSince(lastListed)
        guard left > 0 else { return nil }
        let minutes = max(1, Int((left / 60).rounded(.up)))
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }

    /// Posts the item again as new: a fresh `posts` row takes over the listing
    /// and the old post is retired as 'replaced'. The new post starts with no
    /// likes, no comments and today's date; only what's tied to the item itself
    /// follows it, saves, and "hide" / "not interested". Returns the new post's id.
    /// `seller` nil = the auto re-up job, which has already picked the row.
    static func reup(listingID: String, seller: String?, on db: AppDatabase) async throws -> String {
        var newID = ""
        try await db.tx { t in
            struct Row: Decodable {
                let post_id: String; let author_id: String; let status: String; let post_status: String; let created_at: Date
            }
            // Locking the item row serialises two quick taps into two re-ups, not one lost update.
            guard let cur = try await t.raw("""
                SELECT l.post_id::text AS post_id, p.author_id::text AS author_id, l.status, p.status::text AS post_status,
                       p.created_at
                FROM listing_posts l JOIN posts p ON p.id = l.post_id
                WHERE l.id = \(uuid: listingID) FOR UPDATE OF l
                """).first(decoding: Row.self), cur.post_status == "posted" else {
                throw Abort(.notFound, reason: "Listing not found")
            }
            if let seller, cur.author_id != seller { throw Abort(.forbidden, reason: "Only the seller can re-up this listing") }
            guard cur.status == "available" else { throw Abort(.badRequest, reason: "A sold item can't be re-upped") }
            // The auto re-up job runs on its own schedule (at least a day apart).
            if seller != nil, let wait = reupWait(lastListed: cur.created_at) {
                throw Abort(.tooManyRequests, reason: "You can re-up this listing again in \(wait)")
            }
            struct New: Decodable { let id: String }
            let new = try await t.raw("""
                INSERT INTO posts (author_id, content, content_format, mode, privacy, community_id, post_type, image_urls, image_alts,
                                   lang, translated_text)
                SELECT author_id, content, content_format, mode, privacy, community_id, post_type, image_urls, image_alts,
                       lang, translated_text
                FROM posts WHERE id = \(uuid: cur.post_id)
                RETURNING id::text AS id
                """).first(decoding: New.self)!
            try await t.raw("UPDATE posts SET status = 'replaced' WHERE id = \(uuid: cur.post_id)").run()
            try await t.raw("UPDATE listing_posts SET post_id = \(uuid: new.id), reup_count = reup_count + 1, updated_at = NOW() WHERE id = \(uuid: listingID)").run()
            // The new post has none of its own yet, so these can't collide.
            for table in ["saved_posts", "hidden_posts", "post_feedback"] {
                try await t.raw("UPDATE \(unsafeRaw: table) SET post_id = \(uuid: new.id) WHERE post_id = \(uuid: cur.post_id)").run()
            }
            newID = new.id
        }
        return newID
    }

    /// Items whose auto re-up is due, claimed so no other run takes them: the
    /// next slot moves ahead first, and only the run that still sees the old
    /// slot gets the item. A slow run or a restart can't fire one twice.
    static func claimDueAutoReups(now: Date = Date(), on db: any SQLDatabase) async throws -> [String] {
        struct Due: Decodable { let id: String; let days: Int; let slot: Date }
        let due = try await db.raw("""
            SELECT l.id::text AS id, l.auto_reup_days AS days, l.next_auto_reup_at AS slot
            FROM listing_posts l JOIN posts p ON p.id = l.post_id
            WHERE l.next_auto_reup_at <= \(bind: now) AND l.status = 'available' AND p.status = 'posted'
            ORDER BY l.next_auto_reup_at LIMIT 50
            """).all(decoding: Due.self)
        var claimed: [String] = []
        for d in due {
            let next = advanceAutoReup(d.slot, days: d.days, after: now)
            let moved = try await db.raw("""
                UPDATE listing_posts SET next_auto_reup_at = \(bind: next)
                WHERE id = \(uuid: d.id) AND next_auto_reup_at = \(bind: d.slot)
                RETURNING id
                """).all()
            if !moved.isEmpty { claimed.append(d.id) }
        }
        return claimed
    }

    /// The seller of a post that's a sold listing; nil for anything else.
    static func sellerIfSold(post postID: String, on db: any SQLDatabase) async throws -> String? {
        struct R: Decodable { let seller_id: String }
        return try await db.raw("""
            SELECT p.author_id::text AS seller_id
            FROM listing_posts l JOIN posts p ON p.id = l.post_id
            WHERE p.id = \(uuid: postID) AND l.status = 'sold'
            """).first(decoding: R.self)?.seller_id
    }

    // MARK: auto-reply

    struct AutoReply: Decodable {
        let listing_id: String
        let seller_id: String
        let text: String
    }

    /// The auto-reply owed for a shared post, if it's a live listing with one.
    static func autoReply(forPost postID: String, on db: any SQLDatabase) async throws -> AutoReply? {
        try await db.raw("""
            SELECT l.id::text AS listing_id, p.author_id::text AS seller_id, l.auto_reply AS text
            FROM listing_posts l JOIN posts p ON p.id = l.post_id
            WHERE p.id = \(uuid: postID) AND p.status = 'posted' AND l.auto_reply IS NOT NULL
            """).first(decoding: AutoReply.self)
    }

    /// Claims the one auto-reply this buyer gets for this listing; false if
    /// they've already had it.
    static func claimAutoReply(listingID: String, buyerID: String, on db: any SQLDatabase) async throws -> Bool {
        struct R: Decodable { let listing_id: String }
        return try await db.raw("""
            INSERT INTO listing_auto_replies (listing_id, buyer_id) VALUES (\(uuid: listingID), \(uuid: buyerID))
            ON CONFLICT DO NOTHING RETURNING listing_id::text AS listing_id
            """).first(decoding: R.self) != nil
    }
}

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

    /// What the seller typed, checked.
    struct Details {
        var title: String
        var price: Int64
        var condition: String
        var location: String?
        var autoReply: String?
        var hideFromFriends: Bool
        var latitude: Double? = nil
        var longitude: Double? = nil
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
        let title = d.title?.trimmedText ?? ""
        guard !title.isEmpty else { throw Abort(.badRequest, reason: "Listing title is required") }
        guard title.count <= maxTitle else { throw Abort(.badRequest, reason: "Listing title must be at most \(maxTitle) characters") }
        guard let price = d.price, (0...maxPrice).contains(price) else {
            throw Abort(.badRequest, reason: "Price must be between 0 and \(maxPrice) VND")
        }
        guard let condition = d.condition, conditions.contains(condition) else {
            throw Abort(.badRequest, reason: "Invalid condition")
        }
        let location = d.location?.trimmedText.nilIfEmpty
        if let location, location.count > maxLocation {
            throw Abort(.badRequest, reason: "Location must be at most \(maxLocation) characters")
        }
        let autoReply = d.autoReply?.trimmedText.nilIfEmpty
        if let autoReply, autoReply.count > maxAutoReply {
            throw Abort(.badRequest, reason: "Auto-reply must be at most \(maxAutoReply) characters")
        }
        let point = try coordinates(d.latitude, d.longitude)
        return Details(title: title, price: price, condition: condition, location: location,
                       autoReply: autoReply, hideFromFriends: d.hideFromFriends ?? false,
                       latitude: point?.0, longitude: point?.1)
    }

    /// Returns the listing's id.
    static func create(postID: String, _ d: Details, on db: any SQLDatabase) async throws -> String {
        struct R: Decodable { let id: String }
        return try await db.raw("""
            INSERT INTO listing_posts (post_id, title, price, condition, location, auto_reply, hide_from_friends,
                                       latitude, longitude)
            VALUES (\(uuid: postID), \(bind: d.title), \(bind: d.price), \(bind: d.condition),
                    \(bind: d.location), \(bind: d.autoReply), \(bind: d.hideFromFriends),
                    \(bind: d.latitude), \(bind: d.longitude))
            RETURNING id::text AS id
            """).first(decoding: R.self)!.id
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

    /// SQL: post `p` is a listing shown in community `communityID` (its link
    /// there has `status`).
    static func listedInClause(_ communityID: String, status: String = "posted") -> SQLQueryString {
        """
        (p.post_type = 'listing' AND EXISTS (SELECT 1 FROM listing_posts li
          JOIN listing_communities lci ON lci.listing_id = li.id
          WHERE li.post_id = p.id AND lci.community_id = \(uuid: communityID) AND lci.status = \(bind: status)))
        """
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
              'status', lp.status, 'hide_from_friends', lp.hide_from_friends,
              'has_auto_reply', lp.auto_reply IS NOT NULL,
              'auto_reply', CASE WHEN p.author_id = \(uuid: v) THEN lp.auto_reply END,
              'communities', COALESCE((SELECT json_agg(json_build_object('id', lc.community_id, 'name', lcc.name,
                  'icon_emoji', lcc.icon_emoji) ORDER BY lc.created_at)
                FROM listing_communities lc JOIN communities lcc ON lcc.id = lc.community_id
                WHERE lc.listing_id = lp.id AND lc.status = 'posted'), '[]'))
            FROM listing_posts lp WHERE lp.post_id = p.id
          ) ELSE NULL END)::text AS listing_data,
        """
    }

    // MARK: marketplace

    /// Every available listing in `mode` the viewer may see, newest first —
    /// or only those listed in `communityID`. The feed's visibility rules
    /// (privacy and hide-from-friends, blocks, hidden, muted words) apply.
    static func marketplace(viewer: String, mode: String, query: String?, communityID: String?, sellerID: String? = nil,
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
        if let query {
            let like = "%" + UserStore.escapeLike(query) + "%"
            q = q + " AND (lm.title ILIKE \(bind: like) OR p.content ILIKE \(bind: like))"
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
        var title: String?
        var price: Int64?
        var condition: String?
        var location: String?
        var auto_reply: String?
        var hide_from_friends: Bool?
        var status: String?
        /// Both together; `clear_coordinates` removes the map location.
        var latitude: Double?
        var longitude: Double?
        var clear_coordinates: Bool?
    }

    /// Applies only the fields sent; an empty location or auto-reply clears it.
    static func update(listingID: String, _ p: Patch, on db: any SQLDatabase) async throws {
        var sets: [SQLQueryString] = []
        if let t = p.title {
            let title = t.trimmedText
            guard !title.isEmpty, title.count <= maxTitle else { throw Abort(.badRequest, reason: "Listing title must be 1–\(maxTitle) characters") }
            sets.append("title = \(bind: title)")
        }
        if let price = p.price {
            guard (0...maxPrice).contains(price) else { throw Abort(.badRequest, reason: "Price must be between 0 and \(maxPrice) VND") }
            sets.append("price = \(bind: price)")
        }
        if let c = p.condition {
            guard conditions.contains(c) else { throw Abort(.badRequest, reason: "Invalid condition") }
            sets.append("condition = \(bind: c)")
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
        if let s = p.status {
            guard statuses.contains(s) else { throw Abort(.badRequest, reason: "Invalid status") }
            sets.append("status = \(bind: s)")
        }
        guard !sets.isEmpty else { throw Abort(.badRequest, reason: "Nothing to update") }
        var q: SQLQueryString = "UPDATE listing_posts SET updated_at = NOW()"
        for s in sets { q = q + ", " + s }
        try await db.raw(q + " WHERE id = \(uuid: listingID)").run()
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

import Vapor
import SQLKit

/// Check legit (migration 133): every seller's review post in the Marketplace.
///
/// It's a `posts` row with `post_type = 'legit'`, one per seller and mode, made
/// on first use. It never shows on the profile or in feeds, only on top of the
/// seller's Marketplace page. Buyers review only through a legit card the
/// seller sends them in chat: one review per card, within 3 days, so strangers
/// can't pile onto someone's business. The seller can't delete a review.
enum LegitStore {
    /// The Legit badge needs a high average over enough real sales that a few
    /// friendly reviews can't buy it.
    static let badgeMinAverage = 4.6
    static let badgeMinReviews = 50
    static let maxTitleLength = 100

    static let defaultText = """
        ✅ Reviews
        Reviews from people who bought from me. Each one comes from a buyer I sent a review card to after our deal.
        """

    // MARK: the post

    /// The seller's check-legit post id, made with the default text if they
    /// don't have one yet.
    static func ensurePost(seller: String, mode: String, on db: any SQLDatabase) async throws -> String {
        struct R: Decodable { let id: String }
        try await db.raw("""
            INSERT INTO posts (author_id, content, mode, privacy, post_type, status)
            VALUES (\(uuid: seller), \(bind: defaultText), \(bind: mode), 'public', 'legit', 'posted')
            ON CONFLICT (author_id, mode) WHERE post_type = 'legit' DO NOTHING
            """).run()
        guard let row = try await db.raw("""
            SELECT id::text AS id FROM posts
            WHERE author_id = \(uuid: seller) AND mode = \(bind: mode) AND post_type = 'legit'
            """).first(decoding: R.self) else { throw Abort(.internalServerError) }
        return row.id
    }

    struct Summary: Content {
        /// nil when the seller hid it (only they see it then).
        @NullCoded var post: PostObject?
        @NullCoded var rating_avg: Double?
        var rating_count: Int
        var is_legit: Bool
    }

    static func summary(seller: String, mode: String, viewer: String, on db: any SQLDatabase) async throws -> Summary {
        let postID = try await ensurePost(seller: seller, mode: mode, on: db)
        guard let post = try await PostStore.findById(postID, viewer: viewer, on: db) else {
            return Summary(post: nil, rating_avg: nil, rating_count: 0, is_legit: false)
        }
        let (avg, count) = try await rating(postID: postID, on: db)
        return Summary(post: post, rating_avg: avg, rating_count: count,
                       is_legit: isLegit(average: avg, count: count))
    }

    static func isLegit(average: Double?, count: Int) -> Bool {
        guard let average else { return false }
        return count >= badgeMinReviews && average >= badgeMinAverage
    }

    /// A review counts while its comment is up (a buyer can take theirs down).
    static func rating(postID: String, on db: any SQLDatabase) async throws -> (Double?, Int) {
        struct R: Decodable { let n: Int; let avg: Double? }
        let r = try await db.raw("""
            SELECT COUNT(*)::int AS n, AVG(lr.rating)::float8 AS avg
            FROM legit_reviews lr JOIN comments c ON c.id = lr.comment_id AND c.status = 'posted'
            WHERE lr.post_id = \(uuid: postID)
            """).first(decoding: R.self)
        return (r?.avg.map { ($0 * 10).rounded() / 10 }, r?.n ?? 0)
    }

    // MARK: legit cards

    struct Invite: Content {
        var id: String
        var seller_id: String
        var buyer_id: String
        var item_title: String
        @NullCoded var item_image_url: String?
        /// Whole VND, the item's listed price; nil on cards from before it was shown.
        @NullCoded var item_price: Int64?
        /// How many the buyer bought (migration 139), shown as "× N".
        var item_quantity: Int
        var expires_at: Date
        @NullCoded var reviewed_at: Date?
        @NullCoded var rating: Int?
        /// "open", "reviewed" or "expired".
        var state: String
    }

    static func createInvite(seller: String, buyer: String, mode: String, listingID: String?, itemID: String?,
                             title: String, imageURL: String?, price: Int64, quantity: Int,
                             on db: any SQLDatabase) async throws -> String {
        struct R: Decodable { let id: String }
        return try await db.raw("""
            INSERT INTO legit_invites (seller_id, buyer_id, mode, listing_id, item_id, item_title, item_image_url, item_price,
                                       item_quantity)
            VALUES (\(uuid: seller), \(uuid: buyer), \(bind: mode), \(uuid: listingID), \(uuid: itemID), \(bind: title),
                    \(bind: imageURL), \(bind: price), \(bind: quantity))
            RETURNING id::text AS id
            """).first(decoding: R.self)!.id
    }

    /// The card as the seller or the buyer sees it; nil for anyone else.
    static func invite(_ id: String, viewer: String, on db: any SQLDatabase) async throws -> Invite? {
        struct R: Decodable {
            let id: String; let seller_id: String; let buyer_id: String; let item_title: String
            let item_image_url: String?; let item_price: Int64?; let item_quantity: Int; let expires_at: Date; let reviewed_at: Date?; let rating: Int?; let expired: Bool
        }
        guard let r = try await db.raw("""
            SELECT li.id::text AS id, li.seller_id::text AS seller_id, li.buyer_id::text AS buyer_id,
              li.item_title, li.item_image_url, li.item_price, li.item_quantity::int AS item_quantity, li.expires_at, li.reviewed_at,
              (SELECT lr.rating::int FROM legit_reviews lr WHERE lr.invite_id = li.id) AS rating,
              (li.expires_at <= NOW()) AS expired
            FROM legit_invites li
            WHERE li.id = \(uuid: id) AND (li.seller_id = \(uuid: viewer) OR li.buyer_id = \(uuid: viewer))
            """).first(decoding: R.self) else { return nil }
        let state = r.reviewed_at != nil ? "reviewed" : (r.expired ? "expired" : "open")
        return Invite(id: r.id, seller_id: r.seller_id, buyer_id: r.buyer_id, item_title: r.item_title,
                      item_image_url: r.item_image_url, item_price: r.item_price, item_quantity: r.item_quantity, expires_at: r.expires_at, reviewed_at: r.reviewed_at,
                      rating: r.rating, state: state)
    }

    struct Reviewed { let postID: String; let commentID: String; let sellerID: String }

    /// The buyer's one review from a card: stars plus a comment on the
    /// seller's check-legit post.
    static func review(inviteID: String, buyer: String, rating: Int, text: String,
                       on db: AppDatabase) async throws -> Reviewed {
        guard (0...5).contains(rating) else { throw Abort(.badRequest, reason: "Rating must be 0 to 5 stars") }
        var out: Reviewed!
        try await db.tx { t in
            struct I: Decodable {
                let seller_id: String; let buyer_id: String; let mode: String
                let reviewed_at: Date?; let expired: Bool
            }
            guard let inv = try await t.raw("""
                SELECT seller_id::text AS seller_id, buyer_id::text AS buyer_id, mode, reviewed_at,
                  (expires_at <= NOW()) AS expired
                FROM legit_invites WHERE id = \(uuid: inviteID) FOR UPDATE
                """).first(decoding: I.self), inv.buyer_id == buyer else {
                throw Abort(.notFound, reason: "Review card not found")
            }
            guard inv.reviewed_at == nil else { throw Abort(.conflict, reason: "You've already reviewed this seller with this card") }
            guard !inv.expired else { throw Abort(.gone, reason: "This review card has expired") }
            let postID = try await ensurePost(seller: inv.seller_id, mode: inv.mode, on: t)
            struct C: Decodable { let id: String }
            let comment = try await t.raw("""
                INSERT INTO comments (post_id, author_id, content)
                VALUES (\(uuid: postID), \(uuid: buyer), \(bind: text))
                RETURNING id::text AS id
                """).first(decoding: C.self)!
            try await t.raw("UPDATE posts SET comment_count = comment_count + 1 WHERE id = \(uuid: postID)").run()
            try await t.raw("""
                INSERT INTO legit_reviews (invite_id, post_id, buyer_id, rating, comment_id)
                VALUES (\(uuid: inviteID), \(uuid: postID), \(uuid: buyer), \(bind: rating), \(uuid: comment.id))
                """).run()
            try await t.raw("UPDATE legit_invites SET reviewed_at = NOW() WHERE id = \(uuid: inviteID)").run()
            out = Reviewed(postID: postID, commentID: comment.id, sellerID: inv.seller_id)
        }
        return out
    }
}

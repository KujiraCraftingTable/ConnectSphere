import Vapor

/// A Feed / community post row — port of `buildPostSelect` in
/// `backend/src/models/postModel.js`. Nested objects (`author`, `shared_post`,
/// `event_data`, `poll_data`) come from Postgres `json_build_object`; `tags`
/// from `json_agg`. The same struct decodes the SQL row (JSON columns selected
/// as `jsonb`) and encodes the response.
///
/// Timestamp representation note: Node returns the top-level `created_at` in
/// `.sssZ` form (node-pg parses the column to a JS Date) but nested timestamps
/// like `event_data.starts_at` in Postgres's `+00:00` form. Both are valid
/// ISO-8601 for the same instant; the contract harness normalises them.
struct PostObject: Content {
    var id: String
    @NullCoded var content: String?
    var mode: String
    var privacy: String
    @NullCoded var image_url: String?
    @NullCoded var image_urls: [String]?
    @NullCoded var article_title: String?
    @NullCoded var link_url: String?
    var like_count: Int
    var comment_count: Int
    var share_count: Int
    var created_at: Date
    var post_type: String
    var is_pinned: Bool
    @NullCoded var pinned_at: Date?
    @NullCoded var shared_post_id: String?
    var is_liked: Bool
    var is_saved: Bool
    @NullCoded var shared_post: SharedPost?
    var tags: [String]
    var author: PostAuthor
    @NullCoded var event_data: EventData?
    @NullCoded var poll_data: PollData?
    /// Only present on community-post responses (getPostsByCommunity's outer
    /// wrapper). Plain Optional — the key is *absent* on Feed posts, matching
    /// Node's `buildPostSelect` which doesn't project it at all.
    var community: CommunityRef?

    struct PostAuthor: Content {
        var id: String
        var username: String
        var display_name: String
        @NullCoded var avatar_color: String?
        @NullCoded var avatar_url: String?
        @NullCoded var job_title: String?
        @NullCoded var company: String?
    }
    struct SharedPost: Content {
        var id: String
        @NullCoded var content: String?
        @NullCoded var image_url: String?
        @NullCoded var image_urls: [String]?
        @NullCoded var link_url: String?
        @NullCoded var article_title: String?
        var created_at: Date
        var author: SharedAuthor
        struct SharedAuthor: Content {
            var id: String
            var username: String
            var display_name: String
            @NullCoded var avatar_color: String?
            @NullCoded var avatar_url: String?
        }
    }
    struct EventData: Content {
        var id: String
        var title: String
        @NullCoded var location: String?
        var starts_at: Date
        @NullCoded var ends_at: Date?
        var rsvp_count: Int
        @NullCoded var user_rsvp: String?
    }
    struct PollData: Content {
        @NullCoded var options: [PollOption]?
        @NullCoded var user_vote: String?
        struct PollOption: Content {
            var id: String
            var text: String
            var vote_count: Int
            var position: Int
            @NullCoded var ends_at: Date?
        }
    }
    struct CommunityRef: Content {
        var id: String
        var name: String
        var icon_emoji: String
    }
}

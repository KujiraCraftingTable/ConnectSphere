import Vapor

/// A Feed / community post row. Nested objects (`author`, `shared_post`,
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
    /// Alt text per `image_urls` entry ('' = none); nil when none was written.
    @NullCoded var image_alts: [String]?
    @NullCoded var article_title: String?
    @NullCoded var link_url: String?
    /// Only on the author's own drafts ("draft") and scheduled posts
    /// ("scheduled"); absent for published posts.
    var status: String? = nil
    /// When a scheduled post goes out.
    var publish_at: Date? = nil
    /// Why a community moderator declined it (author's own declined posts only).
    var decline_reason: String? = nil
    /// en | vi | other | none. Set once the translation pipeline has run.
    @NullCoded var lang: String? = nil
    /// The text in the other of en/vi (migration 048); null when there's none
    /// or it's stale after an edit.
    @NullCoded var translated_text: String? = nil
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
    @NullCoded var job_data: JobData?
    @NullCoded var listing_data: ListingData? = nil
    /// Only present on community-post responses (getPostsByCommunity's outer
    /// wrapper). Plain Optional, the key is *absent* on Feed posts (the post
    /// select doesn't project it).
    var community: CommunityRef?
    /// A community shared to the feed (migration 070): its card under the note.
    @NullCoded var shared_community: SharedCommunity? = nil
    /// 'plain' (every post made before Markdown) or 'markdown' (migration 098).
    var content_format: String? = nil

    struct SharedCommunity: Content {
        var id: String
        var name: String
        @NullCoded var cover_url: String?
        var cover_color: String
        var icon_emoji: String
        var member_count: Int
        var privacy: String
    }

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
        @NullCoded var image_alts: [String]?
        @NullCoded var lang: String?
        @NullCoded var translated_text: String?
        var content_format: String? = nil
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
    /// A marketplace listing's details (migration 072). `auto_reply` is only
    /// filled in for the seller.
    struct ListingData: Content {
        var id: String
        var title: String
        var price: Int64
        var condition: String
        @NullCoded var location: String?
        var status: String
        /// How many times the seller re-upped it (migration 093).
        var reup_count: Int = 0
        /// The seller's auto re-up schedule and its next run (migration 095); only they get these.
        @NullCoded var auto_reup: AutoReup? = nil
        @NullCoded var next_auto_reup_at: Date? = nil
        var hide_from_friends: Bool
        var has_auto_reply: Bool
        @NullCoded var auto_reply: String?
        /// The communities it's showing in (migration 073).
        var communities: [ListedIn]? = nil
        /// Where it is on the map (migration 074).
        @NullCoded var latitude: Double? = nil
        @NullCoded var longitude: Double? = nil
        struct ListedIn: Content {
            var id: String
            var name: String
            var icon_emoji: String
        }
        struct AutoReup: Content, Equatable {
            var every_days: Int
            /// 9, 12, 15, 18, 21 or 24 (midnight), Vietnam time.
            var hour: Int
        }
    }
    struct JobData: Content {
        var id: String
        var title: String
        @NullCoded var company: String?
        @NullCoded var location: String?
        @NullCoded var employment_type: String?
        @NullCoded var salary_range: String?
        @NullCoded var application_deadline: Date?
        var interested_count: Int
        var user_interested: Bool
        @NullCoded var company_id: String? = nil
        @NullCoded var company_logo_url: String? = nil
        var company_verified: Bool? = nil
        @NullCoded var work_format: String? = nil
        @NullCoded var level: String? = nil
        @NullCoded var salary_min: Int? = nil
        @NullCoded var salary_max: Int? = nil
        var skills: [String]? = nil
    }
    struct CommunityRef: Content {
        var id: String
        var name: String
        var icon_emoji: String
        @NullCoded var avatar_url: String?
        /// The community's own privacy, and who this post is for: "public"
        /// (anyone) or "members" (migration 075).
        var privacy: String? = nil
        var audience: String? = nil
    }
}

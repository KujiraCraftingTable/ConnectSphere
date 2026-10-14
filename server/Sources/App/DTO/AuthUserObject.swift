import Vapor

/// The `user` object returned by `/api/auth/*` and `/api/auth/me` — a 1:1 port
/// of `getUserById` in `backend/src/routes/authRoutes.js`: every `users` column
/// except `password_hash` / `google_id`, with `display_name` / `bio` /
/// `avatar_url` / `cover_url` persona-resolved from `default_mode`, plus the
/// computed `hobby_setup` / `work_setup` / `has_password` / `interests` / `skills`.
///
/// snake_case property names match the wire contract with no `CodingKeys`
/// boilerplate; `@NullCoded` keeps nullable columns emitted as `null` (Node does).
/// The same struct decodes the SQL row and encodes the response.
struct AuthUserObject: Content {
    var id: String
    var username: String
    var display_name: String
    @NullCoded var bio: String?
    @NullCoded var avatar_color: String?
    @NullCoded var avatar_url: String?
    @NullCoded var location: String?
    @NullCoded var ward_id: String?
    @NullCoded var gender: String?
    @NullCoded var dob: Date?
    @NullCoded var job_title: String?
    @NullCoded var company: String?
    @NullCoded var phone: String?
    @NullCoded var email: String?
    var is_setup: Bool
    var default_mode: String
    @NullCoded var hobby_theme: String?
    @NullCoded var work_theme: String?
    var follower_count: Int
    var following_count: Int
    var post_count: Int
    var created_at: Date
    var updated_at: Date
    @NullCoded var deleted_at: Date?
    @NullCoded var cover_url: String?
    @NullCoded var hobby_display_name: String?
    @NullCoded var hobby_bio: String?
    @NullCoded var hobby_avatar_url: String?
    @NullCoded var hobby_cover_url: String?
    @NullCoded var work_display_name: String?
    @NullCoded var work_bio: String?
    @NullCoded var work_avatar_url: String?
    @NullCoded var work_cover_url: String?
    @NullCoded var dob_visibility: String?
    @NullCoded var age: Int?
    var hobby_setup: Bool
    var work_setup: Bool
    var has_password: Bool
    var allow_friend_requests: Bool
    /// Privacy: off = you never appear in other people's "People you may know".
    var show_in_suggestions: Bool
    /// This persona's profile links to your other one (migration 060).
    var links_other_mode: Bool
    /// The email was confirmed with a code (or by Google) — migration 061.
    var email_verified: Bool
    var interests: [String]
    var skills: [String]
}

/// `{ token, user, is_new_user }` — register / login / google.
struct AuthResponse: Content {
    var token: String
    var user: AuthUserObject
    var is_new_user: Bool
}

/// `{ user }` — /me and /setup.
struct MeResponse: Content {
    var user: AuthUserObject
}

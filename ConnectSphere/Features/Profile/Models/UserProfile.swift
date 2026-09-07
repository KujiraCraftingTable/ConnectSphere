import Foundation

struct UserProfile: Identifiable {
    let id: String
    var name: String
    var username: String
    var avatarColor: String
    var avatarUrl: String? = nil
    var coverUrl: String? = nil
    var bio: String
    // Colleague fields
    var jobTitle: String?
    var company: String?
    var skills: [String]
    // Friend fields
    var interests: [String]
    var location: String?
    var gender: String?
    // Per-mode persona setup status — determines whether the user "exists" in
    // that mode (not set up = hidden from that mode's search/feed, switching
    // to that mode is blocked and the persona creation form is shown instead)
    var hobbySetup: Bool = false
    var workSetup: Bool = false
    // Self-only field (server only returns this in /auth/me and PATCH /users/me)
    var email: String? = nil
    /// Whether a password has been set yet (Google-only accounts = false) — decides which
    /// flow to show (set password vs. change password)
    var hasPassword: Bool = false
    // Displayed age — present in both public and self views, null from server when dob_visibility = private
    var age: Int? = nil
    // Self-only field (server only returns this in /auth/me and PATCH /users/me),
    // same as email/hasPassword above
    var dob: String? = nil
    var dobVisibility: String? = nil
    // Stats
    var followerCount: Int
    var followingCount: Int
    var postCount: Int
    // Number of accepted connections for the mode currently being viewed (backend includes this when fetching a profile)
    var connectionCount: Int = 0
    // Number of mutual friends/connections with the viewer (backend includes this in search/list results)
    var mutualCount: Int = 0
    // AI search score — nil for regular search results
    var score: Double?
}

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
    /// Self-only. Off = strangers can only follow; this user sends requests themselves.
    var allowFriendRequests: Bool = true
    /// Self-only. Off = never shown in other people's "People you may know".
    var showInSuggestions: Bool = true
    /// This persona's profile has the flip button to the other one (on
    /// unless the person turned it off for this mode).
    var linksOtherMode: Bool = true
    /// Self-only. The email was confirmed with a code (or by Google) —
    /// deleting a persona or the account needs it.
    var emailVerified: Bool = false
    /// Self-only. Every sign-in needs an emailed code.
    var twoFactorEnabled: Bool = false
    /// Hobby-only (migration 062): language codes, and a RelationshipStatus raw value.
    var languages: [String] = []
    var relationshipStatus: String? = nil
    /// This persona is locked (migration 064)…
    var isLocked: Bool = false
    /// …and whether the viewer may see past it (theirs, or a connection).
    var canView: Bool = true
    // Displayed age — present in both public and self views, null from server when dob_visibility = private
    var age: Int? = nil
    // Self-only field (server only returns this in /auth/me and PATCH /users/me),
    // same as email/hasPassword above
    var dob: String? = nil
    var dobVisibility: String? = nil
    /// Birthday changes still allowed (2 per account).
    var dobChangesLeft: Int? = nil
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

extension UserProfile {
    /// Someone else's locked persona you're not connected to: only the
    /// name, avatar and cover show.
    var lockedOut: Bool { isLocked && !canView }

    /// Whether they've set up a persona in `mode`.
    func hasPersona(_ mode: AppMode) -> Bool { mode == .hobby ? hobbySetup : workSetup }
}

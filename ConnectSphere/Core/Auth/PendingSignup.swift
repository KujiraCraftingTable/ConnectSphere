import Foundation

/// A manual sign-up between the sign-up form and the end of onboarding.
/// Nothing exists on the server yet. The account (and its @username) is
/// created only when onboarding finishes. Kept in memory only.
struct PendingSignup: Identifiable, Equatable {
    let id = UUID()
    let username: String
    let password: String
    /// Already confirmed with its code; nil when none was given.
    let email: String?
}

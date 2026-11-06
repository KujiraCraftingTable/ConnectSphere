import Foundation

/// The username format the server enforces (`^[a-z0-9_]{3,30}$`), checked as
/// the user types. Shared by sign-up and a Google account's onboarding.
enum UsernameRules {
    static let minLength = 3
    static let maxLength = 30

    /// What's wrong with `name` (already lowercased), or nil when it's fine or
    /// still empty. ASCII only: the server rejects accented letters, so `é`
    /// must not pass here just because it's a letter.
    static func problem(_ name: String) -> String? {
        guard !name.isEmpty else { return nil }
        if name.contains(where: { !(("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "_") }) {
            return Bundle.app.loc("Only letters, numbers, and underscore (_) are allowed")
        }
        if name.count < minLength { return Bundle.app.loc("Username must be at least 3 characters") }
        if name.count > maxLength { return Bundle.app.loc("Username must be at most 30 characters") }
        return nil
    }

    static func isValid(_ name: String) -> Bool { !name.isEmpty && problem(name) == nil }

    static var hint: String {
        Bundle.app.loc("Letters, numbers, and underscore (_) only, at least 3 characters")
    }
}

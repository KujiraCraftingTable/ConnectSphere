import Foundation

/// How often a birthday may change (migration 083). Pure, so it's testable;
/// `UserStore.updateProfile` applies it.
enum BirthdayRules {
    /// For the account's whole life — after that, support makes the change.
    static let maxChanges = 2

    static let limitReason = "You've used both birthday changes. To change it again, email support."

    /// Edit profile sends the birthday on every save; only a different value
    /// is a change. Both sides are `yyyy-MM-dd` (or nil for none).
    static func isChange(from old: String?, to new: String?) -> Bool {
        normalized(old) != normalized(new)
    }

    static func changesLeft(used: Int) -> Int { max(0, maxChanges - used) }

    private static func normalized(_ value: String?) -> String? {
        guard let v = value?.trimmingCharacters(in: .whitespaces), !v.isEmpty else { return nil }
        return String(v.prefix(10))
    }
}

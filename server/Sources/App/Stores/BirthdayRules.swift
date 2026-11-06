import Foundation

/// How often a birthday may change (migration 083). Pure, so it's testable;
/// `UserStore.updateProfile` applies it.
enum BirthdayRules {
    /// For the account's whole life. After that, support makes the change.
    static let maxChanges = 2

    /// ConnectSphere is for people 16 and over (PRODUCT.md). Decree 147/2024 asks
    /// for a parent to register under-16 accounts; we don't offer that, so the
    /// birthday a person declares must make them at least this old.
    static let minimumAge = 16

    static let underageReason = "You must be at least 16 to use ConnectSphere."

    /// `value` is `yyyy-MM-dd` (or an ISO-8601 timestamp, whose first ten
    /// characters are the date). Unparseable values count as not old enough.
    static func isOldEnough(_ value: String, today: Date = Date()) -> Bool {
        guard let born = JSONCoding.dateOnly.date(from: String(value.prefix(10))),
              let cutoff = Calendar(identifier: .gregorian).date(byAdding: .year, value: -minimumAge, to: today)
        else { return false }
        return born <= cutoff
    }

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

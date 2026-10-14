import Foundation

/// An account that signed in on this device, offered on the login screen so
/// nobody has to remember which username goes with which account. No
/// password or token is kept here — signing in still needs the password
/// (or Google).
struct SavedAccount: Codable, Identifiable, Equatable {
    /// The user id: a renamed username still matches its row.
    let id: String
    var username: String
    /// What a password account signs in with (older entries may lack it).
    var email: String?
    var displayName: String
    var avatarUrl: String?
    var avatarColor: String
    /// false = a Google-only account; tapping it signs in with Google.
    var hasPassword: Bool
    var lastUsed: Date
}

/// The device's saved accounts, newest first (at most 5).
struct SavedAccounts {
    static let limit = 5
    private static let key = "savedAccounts"
    var defaults: UserDefaults = .standard

    func all() -> [SavedAccount] {
        guard let data = defaults.data(forKey: Self.key),
              let list = try? JSONDecoder().decode([SavedAccount].self, from: data) else { return [] }
        return list.sorted { $0.lastUsed > $1.lastUsed }
    }

    func remember(_ account: SavedAccount) {
        save([account] + all().filter { $0.id != account.id })
    }

    func forget(id: String) {
        save(all().filter { $0.id != id })
    }

    private func save(_ list: [SavedAccount]) {
        let kept = Array(list.sorted { $0.lastUsed > $1.lastUsed }.prefix(Self.limit))
        defaults.set(try? JSONEncoder().encode(kept), forKey: Self.key)
    }
}

import Foundation

/// An account that signed in on this device, offered on the login screen so
/// nobody has to remember which username goes with which account. No
/// password or token is kept here. Signing in still needs the password
/// (or Google).
struct SavedAccount: Codable, Identifiable, Equatable {
    /// The user id: a renamed username still matches its row.
    let id: String
    var username: String
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

    /// Google-only accounts keep their email in the Keychain, not in this list:
    /// it only tells Google which of the phone's accounts to open.
    func googleHint(for id: String) -> String? { KeychainHelper.load(forKey: Self.hintKey(id)) }

    private static func hintKey(_ id: String) -> String { "google_hint_\(id)" }

    func all() -> [SavedAccount] {
        migrateLegacyEmails()
        guard let data = defaults.data(forKey: Self.key),
              let list = try? JSONDecoder().decode([SavedAccount].self, from: data) else { return [] }
        return list.sorted { $0.lastUsed > $1.lastUsed }
    }

    func remember(_ account: SavedAccount, googleHint: String? = nil) {
        if !account.hasPassword, let googleHint { KeychainHelper.save(googleHint, forKey: Self.hintKey(account.id)) }
        save([account] + all().filter { $0.id != account.id })
    }

    func forget(id: String) {
        KeychainHelper.delete(forKey: Self.hintKey(id))
        save(all().filter { $0.id != id })
    }

    /// Earlier versions stored each account's email here in plain storage.
    /// Moves a Google account's to the Keychain, drops the rest, once.
    private func migrateLegacyEmails() {
        struct Legacy: Decodable { let id: String; let email: String?; let hasPassword: Bool }
        guard let data = defaults.data(forKey: Self.key),
              let legacy = try? JSONDecoder().decode([Legacy].self, from: data),
              legacy.contains(where: { $0.email != nil }),
              let list = try? JSONDecoder().decode([SavedAccount].self, from: data) else { return }
        for entry in legacy where !entry.hasPassword {
            if let email = entry.email { KeychainHelper.save(email, forKey: Self.hintKey(entry.id)) }
        }
        defaults.set(try? JSONEncoder().encode(list), forKey: Self.key)
    }

    private func save(_ list: [SavedAccount]) {
        let kept = Array(list.sorted { $0.lastUsed > $1.lastUsed }.prefix(Self.limit))
        defaults.set(try? JSONEncoder().encode(kept), forKey: Self.key)
    }
}

import Foundation

/// Which edition of the Terms and Privacy Policy was ticked on this phone, so
/// the login screen doesn't ask again for the same edition. Only a version
/// string, no account or personal data. A new edition (`LegalDocs.version`)
/// starts unticked.
struct PolicyConsentMemory {
    private static let key = "acceptedPolicyVersion"
    var defaults: UserDefaults = AppDefaults.store

    var acceptsCurrent: Bool { defaults.string(forKey: Self.key) == LegalDocs.version }

    func remember() { defaults.set(LegalDocs.version, forKey: Self.key) }

    func forget() { defaults.removeObject(forKey: Self.key) }
}

import Foundation

/// The display-name limit the server enforces (`UserStore.maxDisplayNameLength`)
/// — shared by sign-up, persona setup and Edit Profile.
enum DisplayNameRules {
    /// Characters, spaces included. On a 6.1" iPhone a full-length real name
    /// in capitals fits beside a comment's Author badge with a barely visible
    /// shrink; only a name of the very widest letters shrinks much (see
    /// `DisplayNameFitTests`).
    static let maxLength = 30

    /// `text` cut to the limit — applied while typing, so the field simply
    /// stops accepting characters.
    static func capped(_ text: String) -> String {
        text.count > maxLength ? String(text.prefix(maxLength)) : text
    }
}

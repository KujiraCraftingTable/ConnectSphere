import Foundation
import Observation

/// Settings → Language → Translations: what a post or comment in the other
/// language (English ↔ Vietnamese) shows first.
enum TranslationMode: String, CaseIterable {
    case original, translated

    static let storageKey = "translationMode"

    /// Localization key, callers wrap it in `bundle.loc(...)`.
    var label: String { self == .original ? "Show original" : "Show translated" }
}

enum ContentTranslation {
    /// The server translates English ↔ Vietnamese only, when the text is
    /// published. A translation is offered when it exists and the text is in
    /// the language the app *isn't* showing.
    static func isAvailable(lang: String?, translated: String?, appLanguage: AppLanguage) -> Bool {
        guard let lang, lang == "en" || lang == "vi",
              let translated, !translated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return lang != appLanguage.rawValue
    }
}

/// Which items the user flipped away from their default (Settings), for
/// this session. Shared, so a post shows the same way in the feed, its
/// detail page and on a profile. Swapping is instant: the translation came
/// with the post.
@MainActor
@Observable
final class TranslationStore {
    static let shared = TranslationStore()

    private(set) var flipped: Set<String> = []

    static func key(post id: String) -> String { "post:\(id.lowercased())" }
    static func key(comment id: String) -> String { "comment:\(id.lowercased())" }

    func showsTranslation(_ key: String, mode: TranslationMode) -> Bool {
        (mode == .translated) != flipped.contains(key)
    }

    func toggle(_ key: String) {
        if flipped.contains(key) { flipped.remove(key) } else { flipped.insert(key) }
    }
}

import Vapor

/// Runs `ModerationRules` over the text of a request before anything is saved.
/// How strict depends on what the text is: a name or title is seen everywhere
/// and can't ask "are you sure?", a conversation can.
enum ModerationGate {
    enum Strength {
        /// Names and titles: threats, slurs *and* profanity are refused.
        case name
        /// Posts, bios, descriptions: threats and slurs are refused; profanity
        /// is left to the AI check and to reports (like Meta since 2025).
        case text
        /// Comments and messages: as `text`, but profanity first returns
        /// `confirm_required`, and goes through when the app sends `confirm`.
        case chat
    }

    /// The `message` of the 422 that tells the app to ask "Are you sure?".
    static let confirmRequired = "confirm_required"

    static func check(_ fields: [String?], _ strength: Strength, confirm: Bool = false) throws {
        guard let reason = rejection(fields, strength, confirm: confirm) else { return }
        throw InlineError(.unprocessableEntity, reason)
    }

    /// Why the text is refused, or nil. Split from `check` for the socket,
    /// which answers with an acknowledgement rather than an HTTP error.
    static func rejection(_ fields: [String?], _ strength: Strength, confirm: Bool = false) -> String? {
        var nudged = false
        for text in fields.compactMap({ $0 }) where !text.isEmpty {
            switch ModerationRules.verdict(text) {
            case .clean: break
            case .block(let policy): return blockedMessage(policy)
            case .nudge:
                if strength == .name { return "Please choose a name without offensive words." }
                nudged = true
            }
        }
        if nudged, strength == .chat, !confirm { return confirmRequired }
        return nil
    }

    static func blockedMessage(_ policy: ModerationPolicy) -> String {
        "This goes against our rules on \(policy.rawValue.replacingOccurrences(of: "_", with: " "))."
    }
}

import Foundation

/// What the server's content checks say (migration 089): either "ask the person
/// first" (`confirm_required`, for profanity in a comment or message) or why
/// something was refused. Both arrive as a 422.
enum ModerationMessage {
    static let confirmRequired = "confirm_required"

    static func isConfirmRequired(_ error: Error) -> Bool {
        switch error {
        case APIError.serverError(_, let message): return message == confirmRequired
        case WebSocketError.serverError(let message): return message == confirmRequired
        default: return false
        }
    }

    private static let refusalPrefix = "This goes against our rules on "

    /// The server's English refusal in the app's language, or nil for any other message.
    static func localized(_ message: String, bundle: Bundle = .app) -> String? {
        if message == "Please choose a name without offensive words." { return bundle.loc(message) }
        guard message.hasPrefix(refusalPrefix), message.hasSuffix(".") else { return nil }
        let policy = String(message.dropFirst(refusalPrefix.count).dropLast()).replacingOccurrences(of: " ", with: "_")
        guard let reason = ModerationReason(rawValue: policy) else { return nil }
        return String(format: bundle.loc("This goes against our rules on %@."), bundle.loc(reason.displayName).lowercased())
    }
}

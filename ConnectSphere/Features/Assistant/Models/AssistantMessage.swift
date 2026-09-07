import Foundation

/// A single local-only chat message in the assistant's conversation.
/// Ephemeral, in-memory only — resets when the sheet closes (persistence is
/// a future-feature candidate, not v1). NOT the real `Message`/`MessageBubble`
/// Chat model, which is heavily coupled to reactions/receipts/pins/sockets.
struct AssistantMessage: Identifiable {
    let id: String
    let text: String
    let isFromUser: Bool
    let timestamp: Date
    var action: AssistantMessageAction?

    init(id: String = UUID().uuidString, text: String, isFromUser: Bool,
         timestamp: Date = Date(), action: AssistantMessageAction? = nil) {
        self.id = id
        self.text = text
        self.isFromUser = isFromUser
        self.timestamp = timestamp
        self.action = action
    }
}

/// Interactive affordance attached to an assistant reply.
enum AssistantMessageAction: Equatable {
    /// A "Take me there" button that navigates to `target`.
    case navigate(AssistantNavigationTarget)
    /// Inline Yes/No buttons for the one exception to "just do it" — logging
    /// someone out unprompted is disruptive enough to warrant confirmation.
    case confirmLogout
    /// Inline Yes/No buttons for a match the matcher isn't confident about —
    /// the phrase was found, but buried in a longer sentence where it reads as
    /// incidental ("my work profile picture is wrong"). Asking beats silently
    /// changing something the user never requested.
    case confirmIntent(AssistantIntent)
}

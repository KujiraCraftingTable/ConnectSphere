import Foundation

/// Maps API errors to user-friendly display strings.
/// Replaces the 9 identical `private func friendlyError` copies across ViewModels.
/// Uses `Bundle.app` since this is a free function with no `@Environment` access,
/// same convention as `Message.preview`.
extension Error {
    /// A request the app itself called off (a pull-to-refresh iOS cut short, a
    /// screen closed mid-load). Not a failure to tell the person about.
    var isCancellation: Bool { self is CancellationError }
}

func friendlyError(_ error: Error) -> String {
    if case APIError.serverError(_, let msg) = error { return ModerationMessage.localized(msg) ?? ServerMessage.localized(msg) }
    if case APIError.networkError = error { return Bundle.app.loc("Connection error. Check your network.") }
    if case WebSocketError.serverError(let msg) = error { return ModerationMessage.localized(msg) ?? ServerMessage.localized(msg) }
    if case WebSocketError.timeout = error { return Bundle.app.loc("Request timed out. Please try again.") }
    if case WebSocketError.notConnected = error { return Bundle.app.loc("Connection error. Check your network.") }
    // AuthService's own requests carry the server's reason the same way.
    if (error as NSError).domain == "Auth" { return ServerMessage.localized(error.localizedDescription) }
    return Bundle.app.loc("Something went wrong.")
}

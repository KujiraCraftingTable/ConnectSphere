import Foundation

/// Maps API errors to user-friendly display strings.
/// Replaces the 9 identical `private func friendlyError` copies across ViewModels.
/// Uses `Bundle.app` since this is a free function with no `@Environment` access —
/// same convention as `Message.preview`.
func friendlyError(_ error: Error) -> String {
    if case APIError.serverError(_, let msg) = error { return msg }
    if case APIError.networkError = error { return Bundle.app.loc("Connection error. Check your network.") }
    if case WebSocketError.serverError(let msg) = error { return msg }
    if case WebSocketError.timeout = error { return Bundle.app.loc("Request timed out. Please try again.") }
    if case WebSocketError.notConnected = error { return Bundle.app.loc("Connection error. Check your network.") }
    return Bundle.app.loc("Something went wrong.")
}

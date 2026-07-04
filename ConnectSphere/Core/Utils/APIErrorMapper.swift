import Foundation

/// Maps API errors to user-friendly display strings.
/// Replaces the 9 identical `private func friendlyError` copies across ViewModels.
func friendlyError(_ error: Error) -> String {
    if case APIError.serverError(_, let msg) = error { return msg }
    if case APIError.networkError = error { return "Connection error. Check your network." }
    return "Something went wrong."
}

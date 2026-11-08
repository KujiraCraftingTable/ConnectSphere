import Foundation

/// A banned account's requests are refused with this exact message (server
/// `AuthMiddleware.bannedMessage`, migration 089). Spotting it switches the
/// app to `SuspendedView`, where the person can see why and appeal.
enum AccountSuspension {
    static let serverMessage = "This account has been suspended for breaking our Community Standards"

    /// Banned in the mode the request was made in only (server
    /// `AuthMiddleware.bannedInModeMessage`, migration 106).
    static let modeServerMessage = "This profile has been suspended in this mode for breaking our Community Standards"

    static func check(statusCode: Int, message: String?) {
        guard statusCode == 403 else { return }
        // On the main thread: the root view switches screens on it.
        if message == serverMessage {
            Task { @MainActor in NotificationCenter.default.post(name: .accountSuspended, object: nil) }
        } else if message == modeServerMessage {
            Task { @MainActor in NotificationCenter.default.post(name: .modeSuspended, object: nil) }
        }
    }
}

extension Notification.Name {
    static let accountSuspended = Notification.Name("accountSuspended")
    static let modeSuspended = Notification.Name("modeSuspended")
}

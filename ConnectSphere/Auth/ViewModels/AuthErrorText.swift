import Foundation

/// User-facing messages for sign-in / sign-up failures, shared by the auth
/// ViewModels. A request that never reached the server gets its own message so
/// it isn't mistaken for a wrong password or a taken username.
enum AuthErrorText {
    static func unreachable(_ error: Error) -> String? {
        (error as NSError).domain == NSURLErrorDomain
            ? Bundle.app.loc("Cannot reach the server, please check your connection")
            : nil
    }

    static func login(_ error: Error) -> String {
        if let message = unreachable(error) { return message }
        switch (error as NSError).code {
        case 401: return Bundle.app.loc("Invalid username, email or password")
        case 429: return Bundle.app.loc("Too many attempts, please try again later")
        default:  return Bundle.app.loc("Couldn't sign in, please try again")
        }
    }

    static func register(_ error: Error) -> String {
        if let message = unreachable(error) { return message }
        switch (error as NSError).code {
        case 409:
            return error.localizedDescription.localizedCaseInsensitiveContains("email")
                ? Bundle.app.loc("That email is used by another account")
                : Bundle.app.loc("Username already taken")
        // The server's own reason: a wrong or expired code, a bad address.
        case 400: return error.localizedDescription
        case 429: return Bundle.app.loc("Too many attempts, please try again later")
        default:  return Bundle.app.loc("Couldn't create account, please try again")
        }
    }
}

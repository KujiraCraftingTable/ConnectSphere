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
        case 401: return Bundle.app.loc("Invalid username or password")
        case 429: return Bundle.app.loc("Too many attempts, please try again later")
        default:  return Bundle.app.loc("Couldn't sign in, please try again")
        }
    }

    static func register(_ error: Error) -> String {
        if let message = unreachable(error) { return message }
        switch (error as NSError).code {
        case 409: return Bundle.app.loc("Username already taken")
        case 429: return Bundle.app.loc("Too many attempts, please try again later")
        default:  return Bundle.app.loc("Couldn't create account, please try again")
        }
    }
}

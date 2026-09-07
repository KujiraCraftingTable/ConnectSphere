import Foundation

/// Single source of truth for all backend URLs.
/// The base URL is read from Info.plist (key `APIBaseURL`) so it can change per environment
/// (real device/production) without touching code; falls back to localhost for dev.
enum APIConfig {
    static let serverBase: String = {
        // The simulator runs on the same machine as the backend → always use localhost,
        // to avoid breaking when APIBaseURL points at a stale WiFi network's LAN IP.
        #if targetEnvironment(simulator)
        return "http://localhost:3000"
        #else
        return (Bundle.main.object(forInfoDictionaryKey: "APIBaseURL") as? String)
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? "http://localhost:3000"
        #endif
    }()

    static let baseURL = "\(serverBase)/api"

    /// Builds an absolute URL for uploaded media. Message media
    /// (`/uploads/messages/*`) is auth-gated on the server; `AsyncImage` can't
    /// send an Authorization header, so the JWT rides along as `?token=`.
    /// Everything else (avatars, post/story images) is returned as-is.
    static func mediaURL(_ path: String) -> URL? {
        let full = serverBase + path
        guard path.contains("/messages/"),
              let token = KeychainHelper.load(forKey: KeychainHelper.tokenKey),
              var comps = URLComponents(string: full) else {
            return URL(string: full)
        }
        comps.queryItems = (comps.queryItems ?? []) + [URLQueryItem(name: "token", value: token)]
        return comps.url
    }
}

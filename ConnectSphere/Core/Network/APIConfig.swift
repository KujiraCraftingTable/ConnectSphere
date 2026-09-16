import Foundation

/// Single source of truth for all backend URLs.
/// The base URL is read from Info.plist (key `APIBaseURL`) so it can change per environment
/// (real device/production) without touching code; falls back to localhost for dev.
enum APIConfig {
    /// Computed (not cached) so a `devServerOverride` change from
    /// DevServerSettingsView takes effect on the next call, no relaunch
    /// needed — see Endpoint.swift's baseURL for the one place that still
    /// needs its own fix to stay in sync with this.
    static var serverBase: String {
        // The simulator runs on the same machine as the backend → always use localhost,
        // to avoid breaking when APIBaseURL points at a stale WiFi network's LAN IP.
        #if targetEnvironment(simulator)
        return "http://localhost:3000"
        #else
        if let override = UserDefaults.standard.string(forKey: "devServerOverride"),
           !override.isEmpty {
            return override
        }
        return (Bundle.main.object(forInfoDictionaryKey: "APIBaseURL") as? String)
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? "http://localhost:3000"
        #endif
    }

    static var baseURL: String { "\(serverBase)/api" }

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

import Foundation

/// Single source of truth for all backend URLs.
/// The base URL is read from Info.plist (key `APIBaseURL`) so it can change per environment
/// (real device/production) without touching code; falls back to localhost for dev.
enum APIConfig {
    /// Computed (not cached) so a `devServerOverride` change from
    /// DevServerSettingsView takes effect on the next call, no relaunch
    /// needed, see Endpoint.swift's baseURL for the one place that still
    /// needs its own fix to stay in sync with this.
    static var serverBase: String {
        resolveServerBase(
            override: UserDefaults.standard.string(forKey: "devServerOverride"),
            plistValue: Bundle.main.object(forInfoDictionaryKey: "APIBaseURL") as? String,
            isSimulator: isSimulator)
    }

    /// What `serverBase` is when no override is set.
    static var builtInServerBase: String {
        resolveServerBase(
            override: nil,
            plistValue: Bundle.main.object(forInfoDictionaryKey: "APIBaseURL") as? String,
            isSimulator: isSimulator)
    }

    private static var isSimulator: Bool {
        #if targetEnvironment(simulator)
        true
        #else
        false
        #endif
    }

    /// An override always wins. Without one, the simulator runs on the same
    /// machine as the backend, so it uses localhost rather than an
    /// `APIBaseURL` that may point at a stale WiFi network's LAN IP.
    static func resolveServerBase(override: String?, plistValue: String?, isSimulator: Bool) -> String {
        let localhost = "http://localhost:3000"
        if let override = override?.trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty {
            return override
        }
        if isSimulator { return localhost }
        if let plistValue, !plistValue.isEmpty { return plistValue }
        return localhost
    }

    static var baseURL: String { "\(serverBase)/api" }

    /// The URL to load a stored media link from. Our uploads are stored as a
    /// bare path (`/uploads/x.jpg`) and get this device's server address in
    /// front, never the uploader's, which other devices can't reach. Outside
    /// links (YouTube thumbnails, link previews) are used as they are.
    /// Message media (`/uploads/messages/*`) and CVs (`/uploads/cv/*`) are
    /// auth-gated on the server;
    /// `AsyncImage` can't send an Authorization header, so the JWT rides
    /// along as `?token=`.
    static func mediaURL(_ link: String?) -> URL? {
        guard let link = link?.trimmingCharacters(in: .whitespacesAndNewlines), !link.isEmpty else { return nil }
        guard link.hasPrefix("/") else { return URL(string: link) }
        let full = serverBase + link
        guard link.hasPrefix("/uploads/messages/") || link.hasPrefix("/uploads/cv/") || link.hasPrefix("/uploads/hr/"),
              let token = KeychainHelper.load(forKey: KeychainHelper.tokenKey),
              var comps = URLComponents(string: full) else {
            return URL(string: full)
        }
        comps.queryItems = (comps.queryItems ?? []) + [URLQueryItem(name: "token", value: token)]
        return comps.url
    }

    /// The feed-size copy of a public photo (`/uploads/x.jpg` → `/uploads/x_t.jpg`).
    /// The server answers with the original when an older upload has none,
    /// so this never costs a second request.
    static func thumbnailURL(_ link: String?) -> URL? {
        guard let link, link.hasPrefix("/uploads/"),
              !link.hasPrefix("/uploads/messages/"), !link.hasPrefix("/uploads/cv/"),
              let dot = link.lastIndex(of: "."),
              ["jpg", "jpeg", "png", "webp", "heic", "heif"].contains(link[link.index(after: dot)...].lowercased())
        else { return mediaURL(link) }
        return mediaURL(String(link[..<dot]) + "_t.jpg")
    }
}

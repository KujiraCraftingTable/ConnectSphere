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
}

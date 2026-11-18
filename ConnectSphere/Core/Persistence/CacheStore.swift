import Foundation
import SwiftData

/// Owns the SwiftData `ModelContainer` for the offline cache. Stores raw
/// response bodies keyed by a stable string and re-decodes them with the app's
/// normal ISO-8601 decoder on read, so a cached page decodes exactly like a
/// fresh one and DTO changes need no cache migration.
///
/// Every method is best-effort: a missing container, a decode failure, or a
/// disk error yields `nil` / a silent no-op. The app is fully functional with
/// no cache.
@MainActor
final class CacheStore {
    static let shared = CacheStore()

    let container: ModelContainer?
    private let decoder = JSONDecoder.makeISO8601()

    private init() {
        let schema = Schema([CachedResponse.self])
        do {
            container = try ModelContainer(
                for: schema,
                // The UI tests get an empty cache each launch, and the
                // developer's cached profile stays out of their sign-in.
                configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: UITestMode.isActive)])
        } catch {
            #if DEBUG
            print("[CacheStore] ModelContainer unavailable: \(error)")
            #endif
            container = nil
        }
    }

    private var ctx: ModelContext? { container.map { ModelContext($0) } }

    // MARK: raw body I/O

    /// Store the exact bytes the server returned for `key`.
    func put(_ key: String, body: Data) {
        guard let ctx else { return }
        let d = FetchDescriptor<CachedResponse>(predicate: #Predicate { $0.key == key })
        if let existing = (try? ctx.fetch(d))?.first {
            existing.body = body
            existing.cachedAt = .now
        } else {
            ctx.insert(CachedResponse(key: key, body: body))
        }
        try? ctx.save()
    }

    /// Decode the cached body for `key` as `type`, or nil if absent / stale-broken.
    func get<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
        guard let ctx else { return nil }
        let d = FetchDescriptor<CachedResponse>(predicate: #Predicate { $0.key == key })
        guard let body = (try? ctx.fetch(d))?.first?.body else { return nil }
        return try? decoder.decode(T.self, from: body)
    }

    func remove(_ key: String) {
        guard let ctx else { return }
        let d = FetchDescriptor<CachedResponse>(predicate: #Predicate { $0.key == key })
        try? ctx.enumerate(d) { ctx.delete($0) }
        try? ctx.save()
    }

    /// Clear everything, called on logout so the next account never sees the
    /// previous one's cached feed / chats / notifications.
    func wipe() {
        guard let ctx else { return }
        try? ctx.delete(model: CachedResponse.self)
        try? ctx.save()
    }

    // MARK: keys

    enum Key {
        static func feed(_ mode: String) -> String { "feed:\(mode)" }
        static func recommendedFeed(_ mode: String) -> String { "feed-rec:\(mode)" }
        static func conversations(_ mode: String) -> String { "conversations:\(mode)" }
        static func messages(_ conversationId: String) -> String { "messages:\(conversationId)" }
        static let notifications = "notifications"
        static let me = "me"
        static let memberships = "memberships"
    }
}

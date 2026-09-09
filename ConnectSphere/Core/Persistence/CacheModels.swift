import Foundation
import SwiftData

/// SwiftData-backed offline cache for the key read paths (feed, conversation
/// list + messages, notifications, current user, community membership).
///
/// It stores the **raw response body** the server sent, keyed by a stable
/// cache key, and re-decodes it with the app's normal decoder on read. That
/// keeps zero mapping between DTO and a mirror `@Model` — a cached page decodes
/// exactly as a fresh one, and a DTO change needs no cache migration.
///
/// Writes still require the network; this only lets reads render last-known
/// data while offline. Nothing here is a source of truth.
@Model
final class CachedResponse {
    #Unique<CachedResponse>([\.key])
    /// e.g. "feed:hobby", "feed-rec:work", "conversations:hobby",
    /// "messages:<conversationId>", "notifications", "me", "memberships".
    var key: String = ""
    var cachedAt: Date = Date.now
    var body: Data = Data()

    init(key: String, body: Data) {
        self.key = key
        self.cachedAt = .now
        self.body = body
    }
}

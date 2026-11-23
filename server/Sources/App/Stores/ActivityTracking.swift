import SQLKit

/// The "Personalise with my activity" setting (`users.track_activity`,
/// migration 151). Law 91/2025 Art. 29.4 asks social networks for a
/// "do not track" choice; when it's off, nothing passive is recorded and the
/// person's activity shapes no ranking, theirs or anyone else's.
enum ActivityTracking {
    static func isOn(_ userID: String, on db: any SQLDatabase) async throws -> Bool {
        struct R: Decodable { let track_activity: Bool }
        return try await db.raw("SELECT track_activity FROM users WHERE id = \(uuid: userID)")
            .first(decoding: R.self)?.track_activity ?? true
    }

    /// Turning it off erases what tracking produced (Decree 330/2026 Art. 45
    /// expects processing to stop and its data to go). Search sessions stay:
    /// they hold who a search showed, which "Why they fit you" needs, and expire
    /// after 90 days; only the taps and connect/message credits are cleared.
    /// Interest vectors rebuild on their own: their source hash changes once
    /// reactions stop counting (InterestVectorService.signalsCTE).
    static func erase(_ userID: String, on db: any SQLDatabase) async throws {
        try await db.raw("DELETE FROM post_impressions WHERE user_id = \(uuid: userID)").run()
        try await db.raw("""
            UPDATE search_results r SET tapped_at = NULL, connected_at = NULL, messaged_at = NULL
            FROM search_sessions s
            WHERE s.id = r.session_id AND s.user_id = \(uuid: userID)
              AND (r.tapped_at IS NOT NULL OR r.connected_at IS NOT NULL OR r.messaged_at IS NOT NULL)
            """).run()
    }
}

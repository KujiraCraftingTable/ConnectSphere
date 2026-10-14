import Vapor
import SQLKit

/// Lock profile (migration 064): a locked persona shows only name, avatar
/// and cover to people who aren't its connections in that mode.
enum ProfileLock {
    /// The rule, on its own: locked, and you're neither them nor connected.
    static func isLockedOut(locked: Bool, isSelf: Bool, connected: Bool) -> Bool {
        locked && !isSelf && !connected
    }

    /// Whether `viewer` gets only the locked view of `owner`'s `mode` persona.
    static func lockedOut(viewer: String, owner: String, mode: String, on db: any SQLDatabase) async throws -> Bool {
        guard ["hobby", "work"].contains(mode) else { return false }
        if viewer.lowercased() == owner.lowercased() { return false }
        struct R: Decodable { let locked: Bool; let connected: Bool }
        guard let r = try await db.raw("""
            SELECT \(unsafeRaw: mode)_locked AS locked,
              EXISTS (SELECT 1 FROM connections c WHERE c.status = 'accepted' AND c.mode = \(bind: mode)
                AND ((c.requester_id = \(uuid: viewer) AND c.addressee_id = u.id)
                  OR (c.addressee_id = \(uuid: viewer) AND c.requester_id = u.id))) AS connected
            FROM users u WHERE u.id = \(uuid: owner)
            """).first(decoding: R.self) else { return false }
        return isLockedOut(locked: r.locked, isSelf: false, connected: r.connected)
    }
}

import Vapor
import SQLKit

/// The official @connectsphere account: the app's only admin (`app_role =
/// 'admin'`, one at most by migration 104). It posts like anyone, but it can't
/// be reported, blocked or deleted, so its announcements and moderation stay
/// reachable for everyone.
enum OfficialAccount {
    static func isOfficial(_ userID: String?, on db: any SQLDatabase) async throws -> Bool {
        guard let userID, let id = UUID(uuidString: userID) else { return false }
        struct R: Decodable { let one: Int }
        return try await db.raw("""
            SELECT 1 AS one FROM users WHERE id = \(uuid: id.uuidString) AND app_role = 'admin' AND deleted_at IS NULL
            """).first(decoding: R.self) != nil
    }

    /// Refuses an action aimed at the official account (`what` is the
    /// user-facing reason, e.g. "can't be reported").
    static func refuse(_ userID: String?, _ what: String, on db: any SQLDatabase) async throws {
        if try await isOfficial(userID, on: db) {
            throw InlineError(.badRequest, "The official ConnectSphere account \(what)")
        }
    }

    /// Whether the official account is in this conversation (only ever 1:1:
    /// it can't create or join groups).
    static func isInConversation(_ conversationID: String, on db: any SQLDatabase) async throws -> Bool {
        struct R: Decodable { let one: Int }
        return try await db.raw("""
            SELECT 1 AS one FROM conversation_participants cp JOIN users u ON u.id = cp.user_id
            WHERE cp.conversation_id = \(uuid: conversationID) AND u.app_role = 'admin' AND u.deleted_at IS NULL
            """).first(decoding: R.self) != nil
    }

    /// Refuses nicknames and pins in a chat with the official account, on
    /// either side (`what`, e.g. "messages can't be pinned").
    static func refuseInSupportChat(_ conversationID: String, _ what: String, on db: any SQLDatabase) async throws {
        guard try await isInConversation(conversationID, on: db) else { return }
        throw InlineError(.forbidden, "In a chat with ConnectSphere, \(what)")
    }

    /// Only the official account may do this (e.g. cross-post to both modes).
    static func requireOfficial(_ userID: String, on db: any SQLDatabase) async throws {
        guard try await isOfficial(userID, on: db) else {
            throw InlineError(.forbidden, "Only the official account can do this")
        }
    }

    /// Of the keys sent to `PATCH /users/me`, the ones the official account may
    /// change: its name, pictures, colour theme and the mode the change is for.
    /// No location, birthday, about, work, interests or skills.
    static func editableProfileKeys(_ sent: Set<String>) -> Set<String> {
        sent.intersection(["display_name", "avatar_url", "cover_url", "mode", "hobby_theme", "work_theme"])
    }
}

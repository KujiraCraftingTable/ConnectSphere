import Vapor
import SQLKit

/// `swift run App moderator list | grant --user <name> [--role moderator|admin] | revoke --user <name>`
/// — who may moderate the whole app. Kept to the server on purpose: no one,
/// not even an admin, can hand out this role from inside the app.
struct ModeratorCommand: AsyncCommand {
    struct Signature: CommandSignature {
        @Argument(name: "action", help: "list, grant or revoke") var action: String
        @Option(name: "user", help: "Username, with or without the @.") var user: String?
        @Option(name: "role", help: "moderator (default) or admin.") var role: String?
    }

    var help: String { "Lists app moderators and admins, or grants / revokes the role." }

    func run(using context: CommandContext, signature: Signature) async throws {
        let db = context.application.db.sql()
        switch signature.action {
        case "list":
            struct Row: Decodable { let username: String; let app_role: String }
            let rows = try await db.raw("""
                SELECT username, app_role FROM users
                WHERE app_role <> 'user' AND deleted_at IS NULL ORDER BY app_role, username
                """).all(decoding: Row.self)
            if rows.isEmpty { context.console.info("No app moderators or admins yet.") }
            for r in rows { context.console.info("@\(r.username)  \(r.app_role)") }
        case "grant", "revoke":
            guard let name = signature.user?.trimmingCharacters(in: CharacterSet(charactersIn: "@ ")).lowercased(),
                  !name.isEmpty else {
                context.console.error("Pass --user <username>.")
                return
            }
            let role = signature.action == "revoke" ? "user" : (signature.role ?? "moderator")
            guard ["user", "moderator", "admin"].contains(role) else {
                context.console.error("--role must be moderator or admin.")
                return
            }
            struct R: Decodable { let username: String }
            guard let row = try await db.raw("""
                UPDATE users SET app_role = \(bind: role), updated_at = NOW()
                WHERE username = \(bind: name) AND deleted_at IS NULL RETURNING username
                """).first(decoding: R.self) else {
                context.console.error("No active account @\(name).")
                return
            }
            context.console.info(role == "user" ? "@\(row.username) is no longer an app moderator."
                                                : "@\(row.username) is now an app \(role).")
        default:
            context.console.error("Unknown action \(signature.action) — use list, grant or revoke.")
        }
    }
}

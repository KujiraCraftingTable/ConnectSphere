import Vapor
import SQLKit

/// `swift run App community-reports` — lists open reports about whole
/// communities; `--resolve <id>` / `--dismiss <id>` closes one. A community's
/// own admins can't judge reports about it, so the app owner does.
struct CommunityReportsCommand: AsyncCommand {
    struct Signature: CommandSignature {
        @Option(name: "resolve", help: "Mark this report resolved.") var resolve: String?
        @Option(name: "dismiss", help: "Dismiss this report.") var dismiss: String?
    }

    var help: String { "Lists open community reports, or resolves / dismisses one." }

    func run(using context: CommandContext, signature: Signature) async throws {
        let db = context.application.db.sql()
        if let id = signature.resolve ?? signature.dismiss {
            let status = signature.resolve != nil ? "resolved" : "dismissed"
            guard UUID(uuidString: id) != nil else { context.console.error("Not a report id: \(id)"); return }
            struct R: Decodable { let id: String }
            let done = try await db.raw("""
                UPDATE community_reports SET status = \(bind: status), resolved_at = NOW()
                WHERE id = \(uuid: id) AND target_type = 'community' AND status = 'pending'
                RETURNING id::text AS id
                """).first(decoding: R.self)
            context.console.info(done == nil ? "No open community report \(id)." : "Report \(id) \(status).")
            return
        }
        struct Row: Decodable {
            let id: String; let community: String; let reason: String; let detail: String?
            let reporter: String; let created_at: Date
        }
        let rows = try await db.raw("""
            SELECT r.id::text AS id, c.name AS community, r.reason, r.detail, u.username AS reporter, r.created_at
            FROM community_reports r
            JOIN communities c ON c.id = r.target_id
            JOIN users u ON u.id = r.reporter_id
            WHERE r.target_type = 'community' AND r.status = 'pending'
            ORDER BY r.created_at
            """).all(decoding: Row.self)
        guard !rows.isEmpty else { context.console.info("No open community reports."); return }
        for r in rows {
            context.console.info("\(r.id)  \(r.community)  [\(r.reason)] by @\(r.reporter) on \(r.created_at)")
            if let d = r.detail { context.console.info("    \(d)") }
        }
    }
}

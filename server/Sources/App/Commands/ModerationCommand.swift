import Vapor
import SQLKit

/// `swift run App moderation list | show --case <id> | decide --case <id> --decision <d> [--days N] [--note …] --as <username>`
/// — the review queue from the terminal, for when the app isn't to hand.
/// `--as` names the moderator the decision is recorded against.
struct ModerationCommand: AsyncCommand {
    struct Signature: CommandSignature {
        @Argument(name: "action", help: "list, show or decide") var action: String
        @Option(name: "case", help: "Case id.") var caseID: String?
        @Option(name: "decision", help: "keep, remove, remove_strike, restrict or ban") var decision: String?
        @Option(name: "days", help: "Days, for restrict.") var days: Int?
        @Option(name: "note", help: "Why, for the audit log.") var note: String?
        @Option(name: "as", help: "Your moderator username.") var actor: String?
    }

    var help: String { "Lists the moderation queue, shows a case, or decides one." }

    func run(using context: CommandContext, signature: Signature) async throws {
        let app = context.application
        let db = app.db.sql()
        switch signature.action {
        case "list":
            let rows = try await ModerationQueue.cases(status: "open", source: nil, limit: 50, offset: 0, on: db)
            if rows.isEmpty { context.console.info("The queue is empty.") }
            for r in rows {
                context.console.info("\(r.id)  sev \(r.severity)  \(r.policy)  \(r.target_type)  ×\(r.report_count)  @\(r.author?.username ?? "-")  \(r.created_at)")
            }
        case "show":
            guard let id = signature.caseID, let d = try await ModerationQueue.detail(id, on: db) else {
                context.console.error("No such case."); return
            }
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]; enc.dateEncodingStrategy = .iso8601
            context.console.info(String(decoding: try enc.encode(d), as: UTF8.self))
        case "decide":
            guard let id = signature.caseID,
                  let decision = signature.decision.flatMap(ModerationDecision.init(rawValue:)) else {
                context.console.error("Pass --case <id> and --decision keep|remove|remove_strike|restrict|ban."); return
            }
            struct U: Decodable { let id: String }
            guard let name = signature.actor?.trimmingCharacters(in: CharacterSet(charactersIn: "@ ")).lowercased(),
                  let actor = try await db.raw("""
                      SELECT id::text AS id FROM users WHERE username = \(bind: name) AND app_role IN ('moderator', 'admin')
                      """).first(decoding: U.self) else {
                context.console.error("Pass --as <username> of an app moderator or admin."); return
            }
            do {
                let o = try await ModerationService.decide(caseID: id, decision: decision, restrictDays: signature.days,
                                                           note: signature.note, actor: actor.id, on: app.db)
                await ModerationNotices.decided(o, on: db, hub: app.socketHub, logger: app.logger)
                context.console.info("Case \(id): \(o.decision.rawValue)" + (o.restrictedDays.map { ", restricted \($0) days" } ?? ""))
            } catch let e as InlineError {
                context.console.error(e.reason)
            }
        default:
            context.console.error("Unknown action \(signature.action) — use list, show or decide.")
        }
    }
}

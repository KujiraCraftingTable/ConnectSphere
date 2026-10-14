import Vapor
import SQLKit

/// `swift run App verify-company <slug>` — marks a company page Official
/// (`--undo` takes it back). Verification is the app admin's call, not
/// something a page's own admins can do.
struct VerifyCompanyCommand: AsyncCommand {
    struct Signature: CommandSignature {
        @Argument(name: "slug") var slug: String
        @Flag(name: "undo", help: "Remove the Official badge instead.") var undo: Bool
    }

    var help: String { "Marks a company page as Official (verified), or removes it with --undo." }

    func run(using context: CommandContext, signature: Signature) async throws {
        struct R: Decodable { let name: String }
        let db = context.application.db.sql()
        guard let row = try await db.raw("""
            UPDATE companies SET is_verified = \(bind: !signature.undo), updated_at = now()
            WHERE slug = \(bind: signature.slug) RETURNING name
            """).first(decoding: R.self) else {
            context.console.error("No company with slug \(signature.slug)")
            return
        }
        context.console.info(signature.undo ? "\(row.name) is no longer Official." : "\(row.name) is now Official.")
    }
}

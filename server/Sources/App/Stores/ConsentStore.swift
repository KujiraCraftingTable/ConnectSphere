import Vapor
import SQLKit

/// The current Terms of Service and Privacy Policy. Bump `version` whenever the
/// texts in the app (`StaticInfoView`) change in a way people must agree to
/// again, everyone is then asked once more.
enum LegalDocs {
    static let version = "2026-11-07"
    static let documents = ["terms", "privacy"]
}

enum ConsentStore {
    static let notAcceptedReason = "Please accept the Terms of Service and Privacy Policy to continue"

    /// One tick covers both documents; each gets its own row so a later change
    /// to only one of them stays traceable.
    static func record(_ userID: String, on db: any SQLDatabase) async throws {
        for document in LegalDocs.documents {
            try await db.raw("""
                INSERT INTO user_consents (user_id, document, version)
                VALUES (\(uuid: userID), \(bind: document), \(bind: LegalDocs.version))
                ON CONFLICT (user_id, document, version) DO NOTHING
                """).run()
        }
    }

    static func hasAcceptedCurrent(_ userID: String, on db: any SQLDatabase) async throws -> Bool {
        struct Row: Decodable { let n: Int }
        let n = try await db.raw("""
            SELECT COUNT(*)::int AS n FROM user_consents
            WHERE user_id = \(uuid: userID) AND version = \(bind: LegalDocs.version)
            """).first(decoding: Row.self)?.n ?? 0
        return n >= LegalDocs.documents.count
    }

    /// The version a client says the person ticked must be the current one.
    static func requireCurrent(_ sent: String?) throws {
        guard sent == LegalDocs.version else { throw InlineError(.badRequest, notAcceptedReason) }
    }
}

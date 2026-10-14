import Vapor
import SQLKit

/// Codes proving an email typed at sign-up (migration 067) — the account
/// doesn't exist yet, so they're keyed by the address. Same rules as
/// `AccountCodeStore`: 6 digits, bcrypt-hashed, 10 minutes, 5 tries, one a minute.
enum SignupCodeStore {
    /// A fresh code for `email`, replacing any earlier one.
    static func issue(email: String, on db: any SQLDatabase) async throws -> String {
        struct Last: Decodable { let wait: Int }
        if let last = try await db.raw("""
            SELECT CEIL(\(bind: AccountCodeStore.resendSeconds) - EXTRACT(EPOCH FROM (NOW() - created_at)))::int AS wait
            FROM signup_codes WHERE email = \(bind: email)
            """).first(decoding: Last.self), last.wait > 0 {
            throw Abort(.tooManyRequests, reason: "Wait \(last.wait)s before asking for a new code")
        }
        let code = String(format: "%06d", Int.random(in: 0..<1_000_000))
        let hash = try Bcrypt.hash(code, cost: AuthController.bcryptCost)
        try await db.raw("""
            INSERT INTO signup_codes (email, code_hash, expires_at)
            VALUES (\(bind: email), \(bind: hash), NOW() + make_interval(mins => \(bind: AccountCodeStore.ttlMinutes)::int))
            ON CONFLICT (email) DO UPDATE
              SET code_hash = EXCLUDED.code_hash, attempts = 0, expires_at = EXCLUDED.expires_at, created_at = NOW()
            """).run()
        return code
    }

    /// Throws unless `code` is the live one for `email`; a right code is used up.
    static func consume(email: String, code: String, on db: any SQLDatabase) async throws {
        struct Row: Decodable { let code_hash: String; let attempts: Int }
        guard let row = try await db.raw("""
            SELECT code_hash, attempts FROM signup_codes WHERE email = \(bind: email) AND expires_at > NOW()
            """).first(decoding: Row.self), row.attempts < AccountCodeStore.maxAttempts else {
            throw Abort(.badRequest, reason: AccountCodeStore.expiredMessage)
        }
        let typed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard typed.count == 6, (try? Bcrypt.verify(typed, created: row.code_hash)) == true else {
            let attempts = row.attempts + 1
            try await db.raw("UPDATE signup_codes SET attempts = \(bind: attempts) WHERE email = \(bind: email)").run()
            throw Abort(.badRequest, reason: AccountCodeStore.wrongCodeMessage(triesLeft: AccountCodeStore.maxAttempts - attempts))
        }
        try await db.raw("DELETE FROM signup_codes WHERE email = \(bind: email)").run()
    }
}

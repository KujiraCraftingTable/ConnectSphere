import Vapor
import SQLKit

/// One-time 6-digit codes emailed to the account (migration 061): verifying
/// an email, and confirming a persona or account deletion. Stored bcrypt'd,
/// valid 10 minutes, single use, 5 tries.
enum AccountCodeStore {
    enum Purpose: String, CaseIterable {
        case verifyEmail = "verify_email"
        case changeEmail = "change_email"
        case deleteHobby = "delete_hobby"
        case deleteWork = "delete_work"
        case deleteAccount = "delete_account"
        case login
        case twoFactor = "two_factor"

        var mailKind: Mailer.Kind {
            switch self {
            case .verifyEmail: .verifyEmail
            case .changeEmail: .changeEmail
            case .deleteHobby: .deleteHobby
            case .deleteWork: .deleteWork
            case .deleteAccount: .deleteAccount
            case .login: .loginCode
            case .twoFactor: .twoFactor
            }
        }
    }

    static let ttlMinutes = 10
    static let resendSeconds = 60
    static let maxAttempts = 5

    /// Why a code didn't work, as the app shows it.
    static func wrongCodeMessage(triesLeft: Int) -> String {
        triesLeft > 0
            ? "That code isn't right, \(triesLeft) \(triesLeft == 1 ? "try" : "tries") left"
            : "Too many wrong codes. Ask for a new one"
    }
    static let expiredMessage = "This code has expired. Ask for a new one"

    /// A new code (any earlier one for the same purpose stops working).
    /// Refuses a resend within a minute of the last.
    static func issue(user: String, purpose: Purpose, email: String, on db: any SQLDatabase) async throws -> String {
        try await issueWithID(user: user, purpose: purpose, email: email, on: db).code
    }

    /// The code and its row id, for a sign-in, the id is the challenge the
    /// app sends back with the code. `meta` is a short note (the sign-in method).
    static func issueWithID(user: String, purpose: Purpose, email: String, meta: String? = nil,
                            on db: any SQLDatabase) async throws -> (code: String, id: String) {
        struct Last: Decodable { let wait: Int }
        if let last = try await db.raw("""
            SELECT CEIL(\(bind: resendSeconds) - EXTRACT(EPOCH FROM (NOW() - created_at)))::int AS wait
            FROM account_codes WHERE user_id = \(uuid: user) AND purpose = \(bind: purpose.rawValue)
            ORDER BY created_at DESC LIMIT 1
            """).first(decoding: Last.self), last.wait > 0 {
            throw Abort(.tooManyRequests, reason: "Wait \(last.wait)s before asking for a new code")
        }
        let code = String(format: "%06d", Int.random(in: 0..<1_000_000))
        let hash = try Bcrypt.hash(code, cost: AuthController.bcryptCost)
        try await db.raw("""
            UPDATE account_codes SET used_at = NOW()
            WHERE user_id = \(uuid: user) AND purpose = \(bind: purpose.rawValue) AND used_at IS NULL
            """).run()
        struct R: Decodable { let id: String }
        guard let row = try await db.raw("""
            INSERT INTO account_codes (user_id, purpose, email, code_hash, expires_at, meta)
            VALUES (\(uuid: user), \(bind: purpose.rawValue), \(bind: email), \(bind: hash),
                    NOW() + make_interval(mins => \(bind: ttlMinutes)::int), \(bind: meta))
            RETURNING id::text AS id
            """).first(decoding: R.self) else { throw Abort(.internalServerError) }
        return (code, row.id)
    }

    struct Challenge: Decodable {
        let id: String
        let user_id: String
        let email: String
        let meta: String?
    }

    /// A sign-in code sent under a minute ago (signing in again right away
    /// reuses it instead of hitting the resend wait).
    static func recentChallenge(user: String, meta: String, on db: any SQLDatabase) async throws -> Challenge? {
        try await db.raw("""
            SELECT id::text AS id, user_id::text AS user_id, email, meta FROM account_codes
            WHERE user_id = \(uuid: user) AND purpose = 'login' AND meta = \(bind: meta) AND used_at IS NULL
              AND created_at > NOW() - make_interval(secs => \(bind: resendSeconds)::int) AND attempts < \(bind: maxAttempts)
            ORDER BY created_at DESC LIMIT 1
            """).first(decoding: Challenge.self)
    }

    /// Retires a sign-in challenge (a fresh code replaced it).
    static func retire(_ id: String, on db: any SQLDatabase) async throws {
        try await db.raw("UPDATE account_codes SET used_at = NOW() WHERE id = \(uuid: id) AND used_at IS NULL").run()
    }

    /// The sign-in challenge behind `id`, while it can still be answered.
    static func challenge(_ id: String, on db: any SQLDatabase) async throws -> Challenge? {
        guard UUID(uuidString: id) != nil else { return nil }
        return try await db.raw("""
            SELECT id::text AS id, user_id::text AS user_id, email, meta FROM account_codes
            WHERE id = \(uuid: id) AND purpose = 'login' AND used_at IS NULL AND expires_at > NOW()
              AND attempts < \(bind: maxAttempts)
            """).first(decoding: Challenge.self)
    }

    /// Uses up a code; returns the email it was sent to. Each wrong try counts.
    /// `id` pins one sign-in challenge. Its own code, not the user's latest.
    static func consume(user: String, purpose: Purpose, code: String, id: String? = nil,
                        on db: any SQLDatabase) async throws -> String {
        struct Row: Decodable { let id: String; let email: String; let code_hash: String; let attempts: Int }
        var q: SQLQueryString = """
            SELECT id::text AS id, email, code_hash, attempts FROM account_codes
            WHERE user_id = \(uuid: user) AND purpose = \(bind: purpose.rawValue)
              AND used_at IS NULL AND expires_at > NOW()
            """
        if let id { q = q + " AND id = \(uuid: id)" }
        guard let row = try await db.raw(q + " ORDER BY created_at DESC LIMIT 1").first(decoding: Row.self),
              row.attempts < maxAttempts else {
            throw Abort(.badRequest, reason: expiredMessage)
        }
        let typed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard typed.count == 6, (try? Bcrypt.verify(typed, created: row.code_hash)) == true else {
            let attempts = row.attempts + 1
            try await db.raw("""
                UPDATE account_codes SET attempts = \(bind: attempts),
                  used_at = CASE WHEN \(bind: attempts) >= \(bind: maxAttempts) THEN NOW() END
                WHERE id = \(uuid: row.id)
                """).run()
            throw Abort(.badRequest, reason: wrongCodeMessage(triesLeft: maxAttempts - attempts))
        }
        try await db.raw("UPDATE account_codes SET used_at = NOW() WHERE id = \(uuid: row.id)").run()
        return row.email
    }
}

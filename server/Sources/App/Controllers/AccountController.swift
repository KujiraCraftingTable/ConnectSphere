import Vapor
import SQLKit

/// Verified email and deletion (migration 061). Every deletion needs a code
/// sent to the account's verified email — a stolen password isn't enough.
struct AccountController {
    static func register(routes: any RoutesBuilder) {
        let me = routes.grouped("users", "me").grouped(AuthMiddleware()).grouped(RateLimitMiddleware.accountCodes())
        me.post("email", "code", use: sendEmailCode)        // POST /users/me/email/code {email}
        me.post("email", "verify", use: verifyEmail)        // POST /users/me/email/verify {code, current_code?}
        me.post("email", "change-code", use: sendChangeCode) // POST /users/me/email/change-code → current address
        me.post("deletion", "code", use: sendDeletionCode)  // POST /users/me/deletion/code {scope}
        me.delete("personas", ":mode", use: deletePersona)  // DELETE /users/me/personas/:mode {code}
        // DELETE /users/me {code} — UsersController.deleteMe
    }

    struct StatusOK: Content { var status = "ok" }

    // MARK: email

    struct EmailBody: Content { var email: String? }
    struct SentResponse: Content { var status = "ok"; var email: String; var expires_in_minutes = AccountCodeStore.ttlMinutes }

    /// Lowercased, trimmed, and shaped like an address.
    static func cleanEmail(_ raw: String?) -> String? {
        let email = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let parts = email.split(separator: "@", omittingEmptySubsequences: false)
        guard email.count <= 255, parts.count == 2, !parts[0].isEmpty,
              parts[1].contains("."), !parts[1].hasPrefix("."), !parts[1].hasSuffix("."),
              !email.contains(" ") else { return nil }
        return email
    }

    private static func emailTaken(_ email: String, by user: String, on db: any SQLDatabase) async throws -> Bool {
        struct R: Decodable { let id: String }
        return try await db.raw("""
            SELECT id::text AS id FROM users WHERE email = \(bind: email) AND id <> \(uuid: user) AND deleted_at IS NULL
            """).first(decoding: R.self) != nil
    }

    static func sendEmailCode(_ req: Request) async throws -> SentResponse {
        guard let email = cleanEmail(try req.content.decode(EmailBody.self).email) else {
            throw Abort(.badRequest, reason: "Enter a valid email address")
        }
        let db = req.db.sql()
        guard try await !emailTaken(email, by: req.userID, on: db) else {
            throw Abort(.conflict, reason: "That email is used by another account")
        }
        let code = try await AccountCodeStore.issue(user: req.userID, purpose: .verifyEmail, email: email, on: db)
        try await Mailer(req).sendCode(code, to: email, kind: .verifyEmail, minutes: AccountCodeStore.ttlMinutes)
        return SentResponse(email: email)
    }

    struct CodeBody: Content { var code: String? }
    struct VerifyBody: Content { var code: String?; var current_code: String? }
    struct VerifiedResponse: Content { var status = "ok"; var email: String }

    /// Replacing a verified email: a code to the current address first.
    static func sendChangeCode(_ req: Request) async throws -> SentResponse {
        let db = req.db.sql()
        let a = try await account(req.userID, on: db)
        guard a.verified, let email = a.email else { throw Abort(.badRequest, reason: "There's no verified email to change") }
        let code = try await AccountCodeStore.issue(user: req.userID, purpose: .changeEmail, email: email, on: db)
        try await Mailer(req).sendCode(code, to: email, kind: .changeEmail, minutes: AccountCodeStore.ttlMinutes)
        return SentResponse(email: email)
    }

    static func verifyEmail(_ req: Request) async throws -> VerifiedResponse {
        let b = try req.content.decode(VerifyBody.self)
        let db = req.db.sql()
        let a = try await account(req.userID, on: db)
        if a.verified {
            // The owner OKs it from the address already on file.
            _ = try await AccountCodeStore.consume(user: req.userID, purpose: .changeEmail, code: b.current_code ?? "", on: db)
        }
        let email = try await AccountCodeStore.consume(user: req.userID, purpose: .verifyEmail, code: b.code ?? "", on: db)
        guard try await !emailTaken(email, by: req.userID, on: db) else {
            throw Abort(.conflict, reason: "That email is used by another account")
        }
        try await db.raw("""
            UPDATE users SET email = \(bind: email), email_verified_at = NOW(), updated_at = NOW() WHERE id = \(uuid: req.userID)
            """).run()
        return VerifiedResponse(email: email)
    }

    // MARK: deletion

    enum Scope: String { case hobby, work, account }

    private struct Account: Decodable {
        let email: String?
        let verified: Bool
        let hobby: Bool
        let work: Bool
    }

    private static func account(_ user: String, on db: any SQLDatabase) async throws -> Account {
        guard let a = try await db.raw("""
            SELECT email, (email_verified_at IS NOT NULL) AS verified,
                   (hobby_display_name IS NOT NULL) AS hobby, (work_display_name IS NOT NULL) AS work
            FROM users WHERE id = \(uuid: user) AND deleted_at IS NULL
            """).first(decoding: Account.self) else { throw Abort(.notFound, reason: "User not found") }
        return a
    }

    /// A persona can go only while the other one stays; otherwise it's the account.
    static func checkPersona(_ mode: String, hobby: Bool, work: Bool) throws {
        let has = mode == "work" ? work : hobby
        let keeps = mode == "work" ? hobby : work
        guard has else { throw Abort(.badRequest, reason: "You don't have a \(mode == "work" ? "Work" : "Hobby") profile") }
        guard keeps else { throw Abort(.badRequest, reason: "That's your only profile — delete your account instead") }
    }

    private static func purpose(_ scope: Scope) -> AccountCodeStore.Purpose {
        switch scope {
        case .hobby: .deleteHobby
        case .work: .deleteWork
        case .account: .deleteAccount
        }
    }

    struct ScopeBody: Content { var scope: String? }

    static func sendDeletionCode(_ req: Request) async throws -> SentResponse {
        guard let scope = Scope(rawValue: try req.content.decode(ScopeBody.self).scope ?? "") else {
            throw Abort(.badRequest, reason: "scope must be hobby, work or account")
        }
        let db = req.db.sql()
        let a = try await account(req.userID, on: db)
        guard a.verified, let email = a.email else {
            throw Abort(.badRequest, reason: "Add and verify an email first")
        }
        if scope != .account { try checkPersona(scope.rawValue, hobby: a.hobby, work: a.work) }
        let p = purpose(scope)
        let code = try await AccountCodeStore.issue(user: req.userID, purpose: p, email: email, on: db)
        try await Mailer(req).sendCode(code, to: email, kind: p.mailKind, minutes: AccountCodeStore.ttlMinutes)
        return SentResponse(email: email)
    }

    struct PersonaDeleted: Content { var status = "ok"; var default_mode: String }

    static func deletePersona(_ req: Request) async throws -> PersonaDeleted {
        guard let mode = req.parameters.get("mode"), ["hobby", "work"].contains(mode) else {
            throw Abort(.badRequest, reason: "mode must be hobby or work")
        }
        let db = req.db.sql()
        let a = try await account(req.userID, on: db)
        try checkPersona(mode, hobby: a.hobby, work: a.work)
        let code = try req.content.decode(CodeBody.self).code ?? ""
        _ = try await AccountCodeStore.consume(user: req.userID, purpose: mode == "work" ? .deleteWork : .deleteHobby,
                                               code: code, on: db)
        try await AccountDeletionStore.deletePersona(req.userID, mode: mode, on: req.db)
        req.logger.info("persona deleted \(mode) \(req.userID)")
        await BackgroundJobs.refreshEmbedding(req, .profile, id: req.userID)
        return PersonaDeleted(default_mode: mode == "work" ? "hobby" : "work")
    }

    /// DELETE /users/me — the whole account, confirmed with an emailed code.
    static func deleteAccount(_ req: Request) async throws -> StatusOK {
        let code = (try? req.content.decode(CodeBody.self).code) ?? ""
        _ = try await account(req.userID, on: req.db.sql())
        _ = try await AccountCodeStore.consume(user: req.userID, purpose: .deleteAccount, code: code, on: req.db.sql())
        try await UserStore.softDeleteAccount(req.userID, on: req.db)
        req.logger.info("account soft-deleted \(req.userID)")
        return StatusOK()
    }
}

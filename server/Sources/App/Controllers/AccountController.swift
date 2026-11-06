import Vapor
import SQLKit

/// Verified email and deletion (migration 061). Every deletion needs a code
/// sent to the account's verified email. A stolen password isn't enough.
struct AccountController {
    static func register(routes: any RoutesBuilder) {
        let me = routes.grouped("users", "me").grouped(AuthMiddleware()).grouped(RateLimitMiddleware.accountCodes())
        me.post("email", "code", use: sendEmailCode)        // POST /users/me/email/code {email}
        me.post("email", "verify", use: verifyEmail)        // POST /users/me/email/verify {code}
        me.post("email", "change-code", use: sendChangeCode) // POST /users/me/email/change-code → current address
        me.post("email", "change-confirm", use: confirmChange) // POST /users/me/email/change-confirm {code}
        me.post("export", "code", use: sendExportCode)      // POST /users/me/export/code → emailed code
        me.post("export", use: exportData)                  // POST /users/me/export {code | password} → the person's data as JSON
        me.post("deletion", "code", use: sendDeletionCode)  // POST /users/me/deletion/code {scope}
        me.delete("personas", ":mode", use: deletePersona)  // DELETE /users/me/personas/:mode {code}
        me.post("two-factor", "code", use: sendTwoFactorCode) // POST /users/me/two-factor/code
        me.patch("two-factor", use: setTwoFactor)           // PATCH /users/me/two-factor {enabled, code}
        // DELETE /users/me {code}, UsersController.deleteMe
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
    struct DeleteAccountBody: Content { var code: String?; var password: String? }
    struct VerifiedResponse: Content { var status = "ok"; var email: String }
    static let changeWindowMinutes = 15

    /// Replacing a verified email: a code to the current address first.
    static func sendChangeCode(_ req: Request) async throws -> SentResponse {
        let db = req.db.sql()
        let a = try await account(req.userID, on: db)
        guard a.verified, let email = a.email else { throw Abort(.badRequest, reason: "There's no verified email to change") }
        let code = try await AccountCodeStore.issue(user: req.userID, purpose: .changeEmail, email: email, on: db)
        try await Mailer(req).sendCode(code, to: email, kind: .changeEmail, minutes: AccountCodeStore.ttlMinutes)
        return SentResponse(email: email)
    }

    /// Step 1 of replacing a verified email: the code from the current
    /// address unlocks the change for 15 minutes.
    static func confirmChange(_ req: Request) async throws -> StatusOK {
        let code = try req.content.decode(CodeBody.self).code ?? ""
        let db = req.db.sql()
        _ = try await AccountCodeStore.consume(user: req.userID, purpose: .changeEmail, code: code, on: db)
        try await db.raw("""
            UPDATE users SET email_change_until = NOW() + make_interval(mins => \(bind: changeWindowMinutes)::int)
            WHERE id = \(uuid: req.userID)
            """).run()
        return StatusOK()
    }

    static func verifyEmail(_ req: Request) async throws -> VerifiedResponse {
        let code = try req.content.decode(CodeBody.self).code ?? ""
        let db = req.db.sql()
        let a = try await account(req.userID, on: db)
        if a.verified {
            // Replacing a verified email needs step 1 (confirmChange) first.
            struct W: Decodable { let open: Bool }
            guard try await db.raw("SELECT (email_change_until > NOW()) IS TRUE AS open FROM users WHERE id = \(uuid: req.userID)")
                .first(decoding: W.self)?.open == true else {
                throw Abort(.badRequest, reason: "Confirm with a code from your current email first")
            }
        }
        let email = try await AccountCodeStore.consume(user: req.userID, purpose: .verifyEmail, code: code, on: db)
        guard try await !emailTaken(email, by: req.userID, on: db) else {
            throw Abort(.conflict, reason: "That email is used by another account")
        }
        try await db.raw("""
            UPDATE users SET email = \(bind: email), email_verified_at = NOW(), email_change_until = NULL, updated_at = NOW()
            WHERE id = \(uuid: req.userID)
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
        guard keeps else { throw Abort(.badRequest, reason: "That's your only profile. Delete your account instead") }
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

    // MARK: download my data

    /// Proof for an action that is too sensitive for a session alone: the code
    /// emailed to the verified address, or, with no verified email on the
    /// account, its password.
    static func confirmSensitive(_ user: String, purpose: AccountCodeStore.Purpose, code: String?, password: String?,
                                 on db: any SQLDatabase) async throws {
        let a = try await account(user, on: db)
        if a.verified {
            _ = try await AccountCodeStore.consume(user: user, purpose: purpose, code: code ?? "", on: db)
            return
        }
        struct H: Decodable { let password_hash: String? }
        let hash = try await db.raw("SELECT password_hash FROM users WHERE id = \(uuid: user)")
            .first(decoding: H.self)?.password_hash
        guard UserStore.hasRealPassword(hash), let hash, let password, !password.isEmpty,
              (try? Bcrypt.verify(password, created: hash)) == true
        else { throw Abort(.forbidden, reason: "Enter your password to continue") }
    }

    static func sendExportCode(_ req: Request) async throws -> SentResponse {
        let db = req.db.sql()
        let a = try await account(req.userID, on: db)
        guard a.verified, let email = a.email else { throw Abort(.badRequest, reason: "Add and verify an email first") }
        let code = try await AccountCodeStore.issue(user: req.userID, purpose: .exportData, email: email, on: db)
        try await Mailer(req).sendCode(code, to: email, kind: .exportData, minutes: AccountCodeStore.ttlMinutes)
        return SentResponse(email: email)
    }

    static func exportData(_ req: Request) async throws -> Response {
        let body = try? req.content.decode(DeleteAccountBody.self)
        try await confirmSensitive(req.userID, purpose: .exportData, code: body?.code, password: body?.password, on: req.db.sql())
        let json = try await DataExportStore.json(for: req.userID, on: req.db.sql())
        var headers = HTTPHeaders()
        headers.contentType = .json
        headers.replaceOrAdd(name: .contentDisposition, value: "attachment; filename=\"connectsphere-data.json\"")
        return Response(status: .ok, headers: headers, body: .init(string: json))
    }

    // MARK: two-factor sign-in

    static func sendTwoFactorCode(_ req: Request) async throws -> SentResponse {
        let db = req.db.sql()
        let a = try await account(req.userID, on: db)
        guard a.verified, let email = a.email else { throw Abort(.badRequest, reason: "Add and verify an email first") }
        let code = try await AccountCodeStore.issue(user: req.userID, purpose: .twoFactor, email: email, on: db)
        try await Mailer(req).sendCode(code, to: email, kind: .twoFactor, minutes: AccountCodeStore.ttlMinutes)
        return SentResponse(email: email)
    }

    struct TwoFactorBody: Content { var enabled: Bool?; var code: String? }
    struct TwoFactorState: Content { var two_factor_enabled: Bool }

    /// On or off, it takes a code from the verified email. Someone already
    /// signed in can't quietly switch it off.
    static func setTwoFactor(_ req: Request) async throws -> TwoFactorState {
        let b = try req.content.decode(TwoFactorBody.self)
        guard let enabled = b.enabled else { throw Abort(.badRequest, reason: "enabled is required") }
        let db = req.db.sql()
        let a = try await account(req.userID, on: db)
        guard a.verified else { throw Abort(.badRequest, reason: "Add and verify an email first") }
        _ = try await AccountCodeStore.consume(user: req.userID, purpose: .twoFactor, code: b.code ?? "", on: db)
        try await db.raw("UPDATE users SET two_factor_enabled = \(bind: enabled) WHERE id = \(uuid: req.userID)").run()
        return TwoFactorState(two_factor_enabled: enabled)
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

    /// DELETE /users/me, the whole account, confirmed with an emailed code.
    static func deleteAccount(_ req: Request) async throws -> StatusOK {
        let body = try? req.content.decode(DeleteAccountBody.self)
        let db = req.db.sql()
        try await confirmSensitive(req.userID, purpose: .deleteAccount, code: body?.code, password: body?.password, on: db)
        try await UserStore.softDeleteAccount(req.userID, on: req.db, logger: req.logger)
        req.logger.info("account soft-deleted \(req.userID)")
        return StatusOK()
    }
}

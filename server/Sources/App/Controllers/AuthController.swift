import Vapor
import SQLKit

/// Port of `backend/src/routes/authRoutes.js`. Error bodies use the inline
/// `{ "error": "…" }` shape (via `InlineError`), matching the Node handlers.
struct AuthController {
    static let bcryptCost = 12
    static let usernameRegex = try! NSRegularExpression(pattern: "^[a-z0-9_]{3,30}$")
    static let minPasswordLen = 8
    static let otpTTLMinutes = 10

    static func register(routes: any RoutesBuilder) {
        let auth = routes.grouped("auth")
        let limited = auth.grouped(RateLimitMiddleware.passwordAuth())
        let authed = auth.grouped(AuthMiddleware())

        limited.post("register", use: registerUser)
        limited.post("register", "code", use: registerCode)
        limited.post("login", use: login)
        limited.post("login", "verify", use: verifyLogin)
        limited.post("login", "resend", use: resendLogin)
        auth.post("google", use: google)
        authed.get("me", use: me)
        authed.get("check-username", use: checkUsername)
        authed.post("setup", use: setup)
        authed.grouped(RateLimitMiddleware.passwordAuth()).post("change-password", use: changePassword)
        limited.post("forgot-password", use: forgotPassword)
        limited.post("reset-password", use: resetPassword)
    }

    // MARK: helpers

    static func signToken(_ userID: String, _ req: Request) -> String {
        let jwt = req.application.appEnv.jwt
        return JWTHS256.sign(sub: userID.lowercased(), secret: jwt.secret, expiresIn: jwt.expiresIn)
    }

    static func matches(_ regex: NSRegularExpression, _ s: String) -> Bool {
        regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    static func loadUser(_ id: String, mode: String? = nil, _ db: any SQLDatabase) async throws -> AuthUserObject {
        guard let u = try await UserStore.authUser(id: id, mode: mode, on: db) else {
            throw InlineError(.notFound, "User not found")
        }
        return u
    }

    // MARK: POST /register

    struct RegisterBody: Content { var username: String?; var password: String?; var email: String?; var code: String? }

    /// Lowercased and format-checked; 409 when someone has (or had) it —
    /// usernames are never freed.
    static func newUsername(_ raw: String?, on db: any SQLDatabase) async throws -> String {
        let username = (raw ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        guard matches(usernameRegex, username) else {
            throw InlineError(.badRequest, "Username must be 3-30 characters: lowercase letters, numbers, underscore")
        }
        if try await UserStore.usernameTaken(username, on: db) {
            throw InlineError(.conflict, "Username already taken")
        }
        return username
    }

    /// Cleaned; 409 when a live account uses it.
    static func newEmail(_ raw: String, on db: any SQLDatabase) async throws -> String {
        guard let email = AccountController.cleanEmail(raw) else {
            throw InlineError(.badRequest, "Enter a valid email address")
        }
        struct Taken: Decodable { let id: String }
        if try await db.raw("SELECT id::text AS id FROM users WHERE email = \(bind: email) AND deleted_at IS NULL")
            .first(decoding: Taken.self) != nil {
            throw InlineError(.conflict, "That email is used by another account")
        }
        return email
    }

    struct RegisterCodeBody: Content { var username: String?; var email: String? }

    /// Step one of a sign-up with an email: the username and the email are
    /// checked first (so nobody proves an email and then loses the username),
    /// then a code goes to the email.
    static func registerCode(_ req: Request) async throws -> AccountController.SentResponse {
        let b = try req.content.decode(RegisterCodeBody.self)
        let db = req.db.sql()
        _ = try await newUsername(b.username, on: db)
        let email = try await newEmail(b.email ?? "", on: db)
        let code = try await SignupCodeStore.issue(email: email, on: db)
        try await Mailer(req).sendCode(code, to: email, kind: .signup, minutes: AccountCodeStore.ttlMinutes)
        return AccountController.SentResponse(email: email)
    }

    /// @username + password, and an optional email — which, when given, must
    /// come with the code sent to it, so it's verified from the start.
    static func registerUser(_ req: Request) async throws -> Response {
        let body = try req.content.decode(RegisterBody.self)
        let password = body.password ?? ""
        let db = req.db.sql()
        let username = try await newUsername(body.username, on: db)
        guard password.count >= minPasswordLen else {
            throw InlineError(.badRequest, "Password must be at least \(minPasswordLen) characters")
        }
        var email: String?
        if let raw = body.email, !raw.trimmingCharacters(in: .whitespaces).isEmpty {
            let cleaned = try await newEmail(raw, on: db)
            guard let code = body.code, !code.isEmpty else { throw InlineError(.badRequest, "Verify your email first") }
            try await SignupCodeStore.consume(email: cleaned, code: code, on: db)
            email = cleaned
        }

        let hash = try Bcrypt.hash(password, cost: bcryptCost)
        struct NewRow: Decodable { let id: String }
        guard let created = try await db.raw("""
            INSERT INTO users (username, email, email_verified_at, password_hash, display_name, is_setup)
            VALUES (\(bind: username), \(bind: email), CASE WHEN \(bind: email) IS NULL THEN NULL ELSE NOW() END,
                    \(bind: hash), \(bind: username), FALSE)
            RETURNING id
            """).first(decoding: NewRow.self)
        else { throw Abort(.internalServerError) }

        req.logger.info("auth: new password account registered \(created.id)")
        let payload = AuthResponse(token: signToken(created.id, req), user: try await loadUser(created.id, db), is_new_user: true)
        let res = try await payload.encodeResponse(for: req)
        res.status = .created
        return res
    }

    // MARK: POST /login

    /// A Google sign-up's username until onboarding picks the real one.
    static func placeholderUsername() -> String {
        "user_" + String((0..<8).map { _ in "abcdefghijklmnopqrstuvwxyz0123456789".randomElement()! })
    }

    /// Sign-in by @username or email (usernames never contain "@").
    static func loginIdentifier(_ raw: String?) -> String {
        (raw ?? "").trimmingCharacters(in: .whitespaces).lowercased()
    }

    struct LoginBody: Content { var email: String?; var username: String?; var password: String? }

    static func login(_ req: Request) async throws -> Response {
        let body = try req.content.decode(LoginBody.self)
        let password = body.password ?? ""
        let identifier = loginIdentifier(body.username ?? body.email)
        guard !identifier.isEmpty, !password.isEmpty else {
            throw InlineError(.badRequest, "username and password are required")
        }
        let db = req.db.sql()
        guard let user = try await UserStore.findForLogin(identifier, on: db),
              UserStore.hasRealPassword(user.password_hash),
              let hash = user.password_hash,
              (try? Bcrypt.verify(password, created: hash)) == true
        else {
            throw InlineError(.unauthorized, "Invalid username, email or password")
        }
        return try await finishSignIn(user.id, method: "password", isNew: !user.is_setup, req)
    }

    // MARK: POST /google

    struct GoogleBody: Content { var id_token: String? }

    static func google(_ req: Request) async throws -> Response {
        let body = try req.content.decode(GoogleBody.self)
        guard let idToken = body.id_token, !idToken.isEmpty else {
            throw InlineError(.badRequest, "id_token is required")
        }
        let env = req.application.appEnv
        let info: GoogleAuth.TokenInfo
        do {
            info = try await GoogleAuth.verify(
                idToken: idToken, clientId: env.googleClientId, isProduction: env.isProduction,
                client: req.application.http.client.shared, logger: req.logger
            )
        } catch GoogleAuth.GoogleError.notConfigured {
            throw InlineError(.serviceUnavailable, "Google sign-in is not configured")
        } catch GoogleAuth.GoogleError.emailNotVerified {
            throw InlineError(.unauthorized, "Google email is not verified")
        } catch GoogleAuth.GoogleError.missingUserInfo {
            throw InlineError(.unauthorized, "Missing Google user info")
        } catch {
            throw InlineError(.unauthorized, "Invalid Google token")
        }

        let googleId = info.sub!
        let email = info.email!
        // A Google name can be any length; it's only a starting point the
        // user confirms during setup, so it's cut to the limit rather than refused.
        let name = String((info.name ?? String(email.split(separator: "@").first ?? "user"))
            .prefix(UserStore.maxDisplayNameLength))

        let db = req.db.sql()
        struct URow: Decodable { let id: String; let is_setup: Bool }

        var user = try await db.raw("SELECT id, is_setup FROM users WHERE google_id = \(bind: googleId)")
            .first(decoding: URow.self)
        var isNewUser = false

        if user == nil {
            if let existing = try await db.raw("SELECT id, is_setup FROM users WHERE email = \(bind: email)")
                .first(decoding: URow.self) {
                // Google has verified this address.
                try await db.raw("UPDATE users SET google_id = \(bind: googleId), email_verified_at = COALESCE(email_verified_at, NOW()) WHERE id = \(uuid: existing.id)").run()
                user = existing
            } else {
                let username = "user_\(googleId.suffix(8))"
                user = try await db.raw("""
                    INSERT INTO users (google_id, email, email_verified_at, display_name, username, password_hash, avatar_color, is_setup)
                    VALUES (\(bind: googleId), \(bind: email), NOW(), \(bind: name), \(bind: username), '', \(bind: "#1877F2"), FALSE)
                    RETURNING id, is_setup
                    """).first(decoding: URow.self)
                isNewUser = true
            }
        }
        guard let resolved = user else { throw Abort(.internalServerError) }
        return try await finishSignIn(resolved.id, method: "google", isNew: isNewUser || !resolved.is_setup, req)
    }

    // MARK: two-factor sign-in + the sign-in alert

    /// `{ two_factor_required, challenge, email }` — answer with the emailed code.
    struct TwoFactorChallenge: Content {
        var two_factor_required = true
        var challenge: String
        var email: String
    }

    /// The last step of every sign-in: with two-factor on, a code goes to the
    /// verified email and the app gets a challenge instead of a token;
    /// otherwise it's signed in — and told about by email and in-app.
    static func finishSignIn(_ userID: String, method: String, isNew: Bool, _ req: Request) async throws -> Response {
        let db = req.db.sql()
        struct T: Decodable { let on: Bool; let email: String? }
        let t = try await db.raw("""
            SELECT (two_factor_enabled AND email_verified_at IS NOT NULL) AS on, email FROM users WHERE id = \(uuid: userID)
            """).first(decoding: T.self)
        if let t, t.on, let email = t.email {
            if let recent = try await AccountCodeStore.recentChallenge(user: userID, meta: method, on: db) {
                return try await TwoFactorChallenge(challenge: recent.id, email: maskEmail(recent.email)).encodeResponse(for: req)
            }
            let issued = try await AccountCodeStore.issueWithID(user: userID, purpose: .login, email: email, meta: method, on: db)
            try await Mailer(req).sendCode(issued.code, to: email, kind: .loginCode, minutes: AccountCodeStore.ttlMinutes)
            return try await TwoFactorChallenge(challenge: issued.id, email: maskEmail(email)).encodeResponse(for: req)
        }
        signInAlert(userID, method: method, req)
        return try await AuthResponse(token: signToken(userID, req), user: try await loadUser(userID, db), is_new_user: isNew)
            .encodeResponse(for: req)
    }

    struct ChallengeBody: Content { var challenge: String?; var code: String? }

    static func verifyLogin(_ req: Request) async throws -> Response {
        let b = try req.content.decode(ChallengeBody.self)
        let db = req.db.sql()
        guard let ch = try await AccountCodeStore.challenge(b.challenge ?? "", on: db) else {
            throw Abort(.badRequest, reason: AccountCodeStore.expiredMessage)
        }
        _ = try await AccountCodeStore.consume(user: ch.user_id, purpose: .login, code: b.code ?? "", id: ch.id, on: db)
        struct S: Decodable { let is_setup: Bool }
        let setup = try await db.raw("SELECT is_setup FROM users WHERE id = \(uuid: ch.user_id)").first(decoding: S.self)?.is_setup ?? true
        signInAlert(ch.user_id, method: ch.meta ?? "password", req)
        return try await AuthResponse(token: signToken(ch.user_id, req), user: try await loadUser(ch.user_id, db),
                                      is_new_user: !setup).encodeResponse(for: req)
    }

    /// A fresh code for the same sign-in (the old one stops working).
    static func resendLogin(_ req: Request) async throws -> TwoFactorChallenge {
        let db = req.db.sql()
        guard let ch = try await AccountCodeStore.challenge(try req.content.decode(ChallengeBody.self).challenge ?? "", on: db) else {
            throw Abort(.badRequest, reason: AccountCodeStore.expiredMessage)
        }
        let issued = try await AccountCodeStore.issueWithID(user: ch.user_id, purpose: .login, email: ch.email, meta: ch.meta, on: db)
        try await AccountCodeStore.retire(ch.id, on: db)
        try await Mailer(req).sendCode(issued.code, to: ch.email, kind: .loginCode, minutes: AccountCodeStore.ttlMinutes)
        return TwoFactorChallenge(challenge: issued.id, email: maskEmail(ch.email))
    }

    /// "k•••l@gmail.com".
    static func maskEmail(_ email: String) -> String {
        let parts = email.split(separator: "@", maxSplits: 1)
        guard parts.count == 2, let first = parts[0].first else { return email }
        let name = parts[0].count <= 2 ? "\(first)•••" : "\(first)•••\(parts[0].last!)"
        return "\(name)@\(parts[1])"
    }

    /// "Someone just signed in": an in-app notification and an email to the
    /// verified address (which still arrives if someone else is in the
    /// account and clears the notifications). Never blocks the sign-in.
    static func signInAlert(_ userID: String, method: String, _ req: Request) {
        let device = String((req.headers.first(name: "X-Device") ?? req.headers.first(name: .userAgent) ?? "Unknown device").prefix(80))
        let app = req.application
        NotifyService.fireAndForget(req) { d, h, l in
            // No mode: it's about the account, and deleting a persona mustn't wipe it.
            let payload: [String: String] = ["method": method, "device": device]
            _ = await NotifyService.pushUserNotification(
                userID: userID, type: "new_login", actorID: userID, entityType: "user", entityID: userID,
                // Its own group: each sign-in shows separately, never as "+3 more".
                groupTargetID: UUID().uuidString,
                payload: payload, on: d, hub: h, logger: l)
            struct E: Decodable { let email: String? }
            guard let email = try? await d.raw("""
                SELECT email FROM users WHERE id = \(uuid: userID) AND email_verified_at IS NOT NULL
                """).first(decoding: E.self)?.email else { return }
            do { try await Mailer(app: app, logger: l).sendLoginAlert(to: email, method: method, device: device, at: Date()) }
            catch { l.error("sign-in alert mail: \(error)") }
        }
    }

    // MARK: GET /me

    /// `?mode=hobby|work` returns that mode's persona — the app asks for it
    /// on a mode switch, before the new default mode has reached the server.
    static func me(_ req: Request) async throws -> MeResponse {
        let mode = req.query[String.self, at: "mode"]
        if let mode, !["hobby", "work"].contains(mode) { throw InlineError(.badRequest, "mode must be hobby or work") }
        return MeResponse(user: try await loadUser(req.userID, mode: mode, req.db.sql()))
    }

    // MARK: GET /check-username

    struct AvailableResponse: Content { var available: Bool }

    static func checkUsername(_ req: Request) async throws -> AvailableResponse {
        let username = (try? req.query.get(String.self, at: "username"))?
            .trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        guard !username.isEmpty else { throw InlineError(.badRequest, "username is required") }
        let taken = try await UserStore.usernameTaken(username, excluding: req.userID, on: req.db.sql())
        return AvailableResponse(available: !taken)
    }

    // MARK: POST /setup

    struct SetupBody: Content {
        var username: String?
        var display_name: String?
        var dob: String?
        var dob_visibility: String?
        var bio: String?
        var location: String?
        var default_mode: String?
        var job_title: String?
        var company: String?
        var gender: String?
        var interests: [String]?
        var skills: [String]?
    }

    static func setup(_ req: Request) async throws -> MeResponse {
        let b = try req.content.decode(SetupBody.self)
        let skills = try EndorsementStore.cleanSkills(b.skills ?? [])
        let username = (b.username ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        let displayName = (b.display_name ?? "").trimmingCharacters(in: .whitespaces)
        let location = (b.location ?? "").trimmingCharacters(in: .whitespaces)
        guard !username.isEmpty else { throw InlineError(.badRequest, "username is required") }
        // Same format as /register — a Google account picks its name here.
        guard matches(usernameRegex, username) else {
            throw InlineError(.badRequest, "Username must be 3-30 characters: lowercase letters, numbers, underscore")
        }
        guard !displayName.isEmpty else { throw InlineError(.badRequest, "display_name is required") }
        guard UserStore.displayNameFits(displayName) else { throw InlineError(.badRequest, UserStore.displayNameTooLong) }
        guard !location.isEmpty else { throw InlineError(.badRequest, "location is required") }

        let dob = (b.dob ?? "").trimmingCharacters(in: .whitespaces)
        guard !dob.isEmpty else { throw InlineError(.badRequest, "dob is required") }
        guard let dobDate = JSONCoding.dateOnly.date(from: dob) ?? ISO8601DateFormatter().date(from: dob),
              dobDate < Date()
        else { throw InlineError(.badRequest, "dob must be a valid past date") }

        let dobVisibility = b.dob_visibility ?? "private"
        guard ["private", "public"].contains(dobVisibility) else {
            throw InlineError(.badRequest, "dob_visibility must be private or public")
        }

        let db = req.db.sql()
        if try await UserStore.usernameTaken(username, excluding: req.userID, on: db) {
            throw InlineError(.conflict, "Username already taken")
        }

        let mode = ["hobby", "work"].contains(b.default_mode ?? "") ? b.default_mode! : "hobby"
        let gender = ["male", "female", "other"].contains(b.gender ?? "") ? b.gender! : "other"
        let bio = (b.bio?.trimmingCharacters(in: .whitespaces)).flatMap { $0.isEmpty ? nil : $0 }
        let jobTitle = (b.job_title?.trimmingCharacters(in: .whitespaces)).flatMap { $0.isEmpty ? nil : $0 }
        let company = (b.company?.trimmingCharacters(in: .whitespaces)).flatMap { $0.isEmpty ? nil : $0 }

        try await db.raw("""
            UPDATE users SET
              username     = \(bind: username),
              display_name = \(bind: displayName),
              \(unsafeRaw: mode)_display_name = \(bind: displayName),
              dob          = \(bind: dob)::date,
              age          = EXTRACT(YEAR FROM AGE(\(bind: dob)::date))::int,
              bio          = \(bind: bio),
              \(unsafeRaw: mode)_bio = \(bind: bio),
              location     = \(bind: location),
              default_mode = \(bind: mode),
              job_title    = \(bind: jobTitle),
              company      = \(bind: company),
              gender       = \(bind: gender),
              dob_visibility = \(bind: dobVisibility),
              is_setup     = TRUE,
              updated_at   = NOW()
            WHERE id = \(uuid: req.userID)
            """).run()

        try await replaceList(table: "user_interests", col: "interest", userID: req.userID, items: b.interests, db: db)
        try await replaceList(table: "user_skills", col: "skill", userID: req.userID, items: skills, db: db)

        // TODO(phase 5): enqueue profile embed once the queue is ported.
        return MeResponse(user: try await loadUser(req.userID, db))
    }

    static func replaceList(table: String, col: String, userID: String, items: [String]?, db: any SQLDatabase) async throws {
        let clean = Array(Set((items ?? []).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }))
        try await db.raw("DELETE FROM \(unsafeRaw: table) WHERE user_id = \(uuid: userID)").run()
        guard !clean.isEmpty else { return }
        try await db.raw("""
            INSERT INTO \(unsafeRaw: table) (user_id, \(unsafeRaw: col))
            SELECT \(uuid: userID), unnest(\(bind: clean)::text[])
            ON CONFLICT DO NOTHING
            """).run()
    }

    // MARK: POST /change-password

    struct ChangePwBody: Content { var current_password: String?; var new_password: String? }
    struct ChangePwResponse: Content { var status = "ok"; var has_password = true }

    static func changePassword(_ req: Request) async throws -> ChangePwResponse {
        let b = try req.content.decode(ChangePwBody.self)
        let newPassword = b.new_password ?? ""
        guard newPassword.count >= minPasswordLen else {
            throw InlineError(.badRequest, "Password must be at least \(minPasswordLen) characters")
        }
        let db = req.db.sql()
        struct HRow: Decodable { let password_hash: String? }
        guard let row = try await db.raw("SELECT password_hash FROM users WHERE id = \(uuid: req.userID)")
            .first(decoding: HRow.self)
        else { throw InlineError(.notFound, "User not found") }

        if UserStore.hasRealPassword(row.password_hash) {
            guard let cur = b.current_password, let h = row.password_hash,
                  (try? Bcrypt.verify(cur, created: h)) == true
            else { throw InlineError(.unauthorized, "Current password is incorrect") }
        }
        let hash = try Bcrypt.hash(newPassword, cost: bcryptCost)
        try await db.raw("UPDATE users SET password_hash = \(bind: hash), updated_at = NOW() WHERE id = \(uuid: req.userID)").run()
        req.logger.info("auth: password changed \(req.userID)")
        return ChangePwResponse()
    }

    // MARK: POST /forgot-password

    struct ForgotBody: Content { var identifier: String? }
    struct ForgotResponse: Content {
        var status = "ok"
        var message = "If the account has an email on file, a code has been sent"
    }

    static func forgotPassword(_ req: Request) async throws -> ForgotResponse {
        let identifier = loginIdentifier(try req.content.decode(ForgotBody.self).identifier)
        guard !identifier.isEmpty else { throw InlineError(.badRequest, "identifier is required") }

        let db = req.db.sql()
        struct URow: Decodable { let id: String; let email: String? }
        // Only a verified email gets the code — an unproven one could be anyone's.
        let user = try await db.raw("""
            SELECT id, email FROM users
            WHERE (username = \(bind: identifier) OR email = \(bind: identifier))
              AND deleted_at IS NULL AND email_verified_at IS NOT NULL
            """).first(decoding: URow.self)
        guard let user, let email = user.email, !email.isEmpty else { return ForgotResponse() }

        let otp = String(format: "%06d", Int.random(in: 0..<1_000_000))
        let otpHash = try Bcrypt.hash(otp, cost: bcryptCost)
        try await db.raw("UPDATE password_resets SET used_at = NOW() WHERE user_id = \(uuid: user.id) AND used_at IS NULL").run()
        try await db.raw("""
            INSERT INTO password_resets (user_id, otp_hash, expires_at)
            VALUES (\(uuid: user.id), \(bind: otpHash), NOW() + INTERVAL '\(unsafeRaw: String(otpTTLMinutes)) minutes')
            """).run()

        // The response never says whether an email went out (it would reveal
        // which identifiers have one), so a send failure is only logged.
        do { try await Mailer(req).sendCode(otp, to: email, kind: .passwordReset, minutes: otpTTLMinutes) }
        catch { req.logger.error("forgot-password: \(error)") }
        return ForgotResponse()
    }

    // MARK: POST /reset-password

    struct ResetBody: Content { var identifier: String?; var otp: String?; var new_password: String? }
    struct StatusOKResponse: Content { var status = "ok" }

    static func resetPassword(_ req: Request) async throws -> StatusOKResponse {
        let b = try req.content.decode(ResetBody.self)
        let identifier = loginIdentifier(b.identifier)
        let otp = (b.otp ?? "").trimmingCharacters(in: .whitespaces)
        let newPassword = b.new_password ?? ""
        guard !identifier.isEmpty, !otp.isEmpty else {
            throw InlineError(.badRequest, "identifier and otp are required")
        }
        guard newPassword.count >= minPasswordLen else {
            throw InlineError(.badRequest, "Password must be at least \(minPasswordLen) characters")
        }
        let invalid = InlineError(.unauthorized, "Invalid or expired code")

        let db = req.db.sql()
        struct URow: Decodable { let id: String }
        guard let user = try await db.raw("""
            SELECT id FROM users WHERE (username = \(bind: identifier) OR email = \(bind: identifier)) AND deleted_at IS NULL
            """)
            .first(decoding: URow.self)
        else { throw invalid }

        struct RRow: Decodable { let id: String; let otp_hash: String }
        guard let reset = try await db.raw("""
            SELECT id, otp_hash FROM password_resets
            WHERE user_id = \(uuid: user.id) AND used_at IS NULL AND expires_at > NOW()
            ORDER BY created_at DESC LIMIT 1
            """).first(decoding: RRow.self),
            (try? Bcrypt.verify(otp, created: reset.otp_hash)) == true
        else { throw invalid }

        let hash = try Bcrypt.hash(newPassword, cost: bcryptCost)
        try await db.raw("UPDATE users SET password_hash = \(bind: hash), updated_at = NOW() WHERE id = \(uuid: user.id)").run()
        try await db.raw("UPDATE password_resets SET used_at = NOW() WHERE id = \(uuid: reset.id)").run()
        req.logger.info("auth: password reset via OTP \(user.id)")
        return StatusOKResponse()
    }
}

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
        limited.post("login", use: login)
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

    static func loadUser(_ id: String, _ db: any SQLDatabase) async throws -> AuthUserObject {
        guard let u = try await UserStore.authUser(id: id, on: db) else {
            throw InlineError(.notFound, "User not found")
        }
        return u
    }

    // MARK: POST /register

    struct RegisterBody: Content { var username: String?; var password: String? }

    static func registerUser(_ req: Request) async throws -> Response {
        let body = try req.content.decode(RegisterBody.self)
        let username = (body.username ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        let password = body.password ?? ""

        guard !username.isEmpty, matches(usernameRegex, username) else {
            throw InlineError(.badRequest, "Username must be 3-30 characters: lowercase letters, numbers, underscore")
        }
        guard password.count >= minPasswordLen else {
            throw InlineError(.badRequest, "Password must be at least \(minPasswordLen) characters")
        }

        let db = req.db.sql()
        if try await UserStore.usernameTaken(username, on: db) {
            throw InlineError(.conflict, "Username already taken")
        }

        let hash = try Bcrypt.hash(password, cost: bcryptCost)
        struct NewRow: Decodable { let id: String }
        guard let created = try await db.raw("""
            INSERT INTO users (username, password_hash, display_name, is_setup)
            VALUES (\(bind: username), \(bind: hash), \(bind: username), FALSE)
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

    struct LoginBody: Content { var username: String?; var password: String? }

    static func login(_ req: Request) async throws -> AuthResponse {
        let body = try req.content.decode(LoginBody.self)
        let username = (body.username ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        let password = body.password ?? ""
        guard !username.isEmpty, !password.isEmpty else {
            throw InlineError(.badRequest, "username and password are required")
        }
        let db = req.db.sql()
        guard let user = try await UserStore.findByUsername(username, on: db),
              UserStore.hasRealPassword(user.password_hash),
              let hash = user.password_hash,
              (try? Bcrypt.verify(password, created: hash)) == true
        else {
            throw InlineError(.unauthorized, "Invalid username or password")
        }
        return AuthResponse(token: signToken(user.id, req), user: try await loadUser(user.id, db), is_new_user: !user.is_setup)
    }

    // MARK: POST /google

    struct GoogleBody: Content { var id_token: String? }

    static func google(_ req: Request) async throws -> AuthResponse {
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
                try await db.raw("UPDATE users SET google_id = \(bind: googleId) WHERE id = \(uuid: existing.id)").run()
                user = existing
            } else {
                let username = "user_\(googleId.suffix(8))"
                user = try await db.raw("""
                    INSERT INTO users (google_id, email, display_name, username, password_hash, avatar_color, is_setup)
                    VALUES (\(bind: googleId), \(bind: email), \(bind: name), \(bind: username), '', \(bind: "#1877F2"), FALSE)
                    RETURNING id, is_setup
                    """).first(decoding: URow.self)
                isNewUser = true
            }
        }
        guard let resolved = user else { throw Abort(.internalServerError) }
        return AuthResponse(
            token: signToken(resolved.id, req),
            user: try await loadUser(resolved.id, db),
            is_new_user: isNewUser || !resolved.is_setup
        )
    }

    // MARK: GET /me

    static func me(_ req: Request) async throws -> MeResponse {
        MeResponse(user: try await loadUser(req.userID, req.db.sql()))
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
        let identifier = (try req.content.decode(ForgotBody.self).identifier ?? "")
            .trimmingCharacters(in: .whitespaces).lowercased()
        guard !identifier.isEmpty else { throw InlineError(.badRequest, "identifier is required") }

        let db = req.db.sql()
        struct URow: Decodable { let id: String; let email: String? }
        let user = try await db.raw("SELECT id, email FROM users WHERE username = \(bind: identifier) OR email = \(bind: identifier)")
            .first(decoding: URow.self)
        guard let user, let email = user.email, !email.isEmpty else { return ForgotResponse() }

        let otp = String(format: "%06d", Int.random(in: 0..<1_000_000))
        let otpHash = try Bcrypt.hash(otp, cost: bcryptCost)
        try await db.raw("UPDATE password_resets SET used_at = NOW() WHERE user_id = \(uuid: user.id) AND used_at IS NULL").run()
        try await db.raw("""
            INSERT INTO password_resets (user_id, otp_hash, expires_at)
            VALUES (\(uuid: user.id), \(bind: otpHash), NOW() + INTERVAL '\(unsafeRaw: String(otpTTLMinutes)) minutes')
            """).run()

        let env = req.application.appEnv
        await Mailer(mail: env.mail, logger: req.logger).sendPasswordResetOTP(email: email, otp: otp)
        return ForgotResponse()
    }

    // MARK: POST /reset-password

    struct ResetBody: Content { var identifier: String?; var otp: String?; var new_password: String? }
    struct StatusOKResponse: Content { var status = "ok" }

    static func resetPassword(_ req: Request) async throws -> StatusOKResponse {
        let b = try req.content.decode(ResetBody.self)
        let identifier = (b.identifier ?? "").trimmingCharacters(in: .whitespaces).lowercased()
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
        guard let user = try await db.raw("SELECT id FROM users WHERE username = \(bind: identifier) OR email = \(bind: identifier)")
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

import Vapor
import SQLKit

/// Port of `backend/src/controllers/usersController.js` (+ `userRoutes.js` order).
/// All routes require auth. `/me*` and `/blocked` are registered before `/:id`.
struct UsersController {
    static func register(routes: any RoutesBuilder) {
        let users = routes.grouped("users").grouped(AuthMiddleware())

        users.get(use: listUsers)                                  // GET  /api/users
        users.patch("me", use: updateMe)                           // PATCH /api/users/me
        // DELETE /api/users/me — confirmed with an emailed code (AccountController).
        users.grouped(RateLimitMiddleware.accountCodes()).delete("me", use: AccountController.deleteAccount)
        users.post("me", "personas", use: createPersona)           // POST /api/users/me/personas
        users.patch("me", "default-mode", use: updateDefaultMode)  // PATCH /api/users/me/default-mode
        users.get("blocked", use: listBlocked)                     // GET  /api/users/blocked
        users.post(":id", "block", use: blockUser)                 // POST /api/users/:id/block
        users.delete(":id", "block", use: unblockUser)             // DELETE /api/users/:id/block
        users.get(":id", "blocked", use: blockStatus)              // GET  /api/users/:id/blocked
        users.get(":id", use: getUser)                             // GET  /api/users/:id
    }

    static func mode(from req: Request) -> String? {
        let m = (try? req.query.get(String.self, at: "mode")) ?? (try? req.content.get(String.self, at: "mode"))
        return ["hobby", "work"].contains(m ?? "") ? m : nil
    }

    // MARK: GET /api/users

    static func listUsers(_ req: Request) async throws -> PaginatedResponse<SearchUserObject> {
        let db = req.db.sql()
        let m = try? req.query.get(String.self, at: "mode")
        let mode = ["hobby", "work"].contains(m ?? "") ? m : nil
        let search = (try? req.query.get(String.self, at: "search")).flatMap { $0.isEmpty ? nil : $0 }
        let limit = (try? req.query.get(Int.self, at: "limit")) ?? 20
        let offset = (try? req.query.get(Int.self, at: "offset")) ?? 0

        async let rows = UserStore.findAll(
            .init(mode: mode, search: search, viewerID: req.userID, limit: limit, offset: offset), on: db)
        async let total = UserStore.countAll(mode: mode, search: search, viewerID: req.userID, on: db)
        return PaginatedResponse(data: try await rows,
                                 pagination: .init(total: try await total, limit: limit, offset: offset))
    }

    // MARK: GET /api/users/:id

    static func getUser(_ req: Request) async throws -> DataResponse<PublicUserObject> {
        let id = req.parameters.get("id")!
        let db = req.db.sql()
        if try await UserStore.hasBlocked(id, req.userID, on: db) {
            throw Abort(.notFound, reason: "User not found")
        }
        let viewMode = mode(from: req)
        guard var user = try await UserStore.findById(id, mode: viewMode, on: db) else {
            throw Abort(.notFound, reason: "User not found")
        }
        let lockedOut = try await ProfileLock.lockedOut(viewer: req.userID, owner: id,
                                                        mode: viewMode ?? user.core.default_mode, on: db)
        user.can_view = !lockedOut
        if lockedOut { user.trimForLockedOut() }
        return DataResponse(data: user)
    }

    // MARK: block graph

    static func blockUser(_ req: Request) async throws -> BlockedFlagResponse {
        let id = req.parameters.get("id")!
        guard id != req.userID else { throw InlineError(.badRequest, "Cannot block yourself") }
        let db = req.db.sql()
        struct R: Decodable { let id: String }
        guard try await db.raw("SELECT id FROM users WHERE id = \(uuid: id)").first(decoding: R.self) != nil else {
            throw Abort(.notFound, reason: "User not found")
        }
        try await UserStore.block(req.userID, id, on: req.db)
        return BlockedFlagResponse(blocked: true)
    }

    static func unblockUser(_ req: Request) async throws -> BlockedFlagResponse {
        try await UserStore.unblock(req.userID, req.parameters.get("id")!, on: req.db.sql())
        return BlockedFlagResponse(blocked: false)
    }

    static func blockStatus(_ req: Request) async throws -> BlockStatusResponse {
        let id = req.parameters.get("id")!
        let db = req.db.sql()
        async let blocked = UserStore.hasBlocked(req.userID, id, on: db)
        async let either = UserStore.isBlockedEitherWay(req.userID, id, on: db)
        return BlockStatusResponse(blocked: try await blocked, blockedEitherWay: try await either)
    }

    static func listBlocked(_ req: Request) async throws -> DataListResponse<BlockedUserObject> {
        DataListResponse(data: try await UserStore.listBlocked(req.userID, on: req.db.sql()))
    }

    // MARK: PATCH /api/users/me

    struct UpdateMeBody: Content {
        var display_name: String?
        var bio: String?
        var location: String?
        var job_title: String?
        var company: String?
        var avatar_url: String?
        var cover_url: String?
        var dob: String?
        var gender: String?
        var dob_visibility: String?
        var interests: [String]?
        var skills: [String]?
        var email: String?
        var mode: String?
        /// Privacy: off = strangers can only follow, not send friend requests.
        var allow_friend_requests: Bool?
        var show_in_suggestions: Bool?
        /// The current mode's "See my other profile" button (migration 060).
        var links_other_mode: Bool?
        /// Lock the current mode's profile (migration 064).
        var locked: Bool?
        /// Hobby-only (migration 062).
        var languages: [String]?
        var relationship_status: String?
    }

    static let relationshipStatuses: Set<String> = [
        "single", "in_relationship", "engaged", "married", "civil_union", "domestic_partnership",
        "open_relationship", "complicated", "separated", "divorced", "widowed",
    ]
    static let maxLanguages = 10

    /// Trimmed, de-duplicated ignoring case, at most 10 of ≤ 40 characters.
    static func cleanLanguages(_ list: [String]) throws -> [String] {
        var seen = Set<String>()
        let clean = list.map { $0.trimmedText }.filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
        guard clean.count <= maxLanguages, clean.allSatisfy({ $0.count <= 40 }) else {
            throw InlineError(.badRequest, "Up to \(maxLanguages) languages, each at most 40 characters")
        }
        return clean
    }

    static func updateMe(_ req: Request) async throws -> DataResponse<PrivateUserObject> {
        let raw = try req.content.decode(UpdateMeBody.self)
        // Before anything is written, so a bad list doesn't leave half an update.
        var skills = raw.skills
        if let picks = skills { skills = try await SkillStore.cleanPicks(picks, userID: req.userID, on: req.db.sql()) }
        // Which keys were actually present in the JSON body.
        let presentKeys: Set<String> = {
            guard let dict = try? req.content.decode([String: AnyCodableValue].self) else { return [] }
            return Set(dict.keys)
        }()
        func sent(_ key: String) -> Bool { presentKeys.contains(key) }

        var mode = raw.mode ?? (try? req.query.get(String.self, at: "mode"))
        let sdb = req.db.sql()
        if !["hobby", "work"].contains(mode ?? "") {
            struct M: Decodable { let default_mode: String? }
            mode = try await sdb.raw("SELECT default_mode FROM users WHERE id = \(uuid: req.userID)")
                .first(decoding: M.self)?.default_mode ?? "hobby"
        }

        if sent("display_name"), (raw.display_name ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
            throw InlineError(.badRequest, "display_name cannot be empty")
        }
        if sent("display_name"), !UserStore.displayNameFits((raw.display_name ?? "").trimmingCharacters(in: .whitespaces)) {
            throw InlineError(.badRequest, UserStore.displayNameTooLong)
        }
        if sent("bio"), let bio = raw.bio, bio.count > 500 {
            throw InlineError(.badRequest, "bio must be at most 500 characters")
        }
        if sent("gender"), !["male", "female", "other"].contains(raw.gender ?? "") {
            throw InlineError(.badRequest, "Invalid gender")
        }
        if sent("dob_visibility"), !["private", "public"].contains(raw.dob_visibility ?? "") {
            throw InlineError(.badRequest, "dob_visibility must be private or public")
        }

        // The email changes only through a code (AccountController), never
        // here — or a stolen password could redirect the deletion codes.
        if sent("email") {
            struct E: Decodable { let email: String? }
            let current = try await sdb.raw("SELECT email FROM users WHERE id = \(uuid: req.userID)").first(decoding: E.self)?.email
            let sentEmail = (raw.email ?? "").trimmingCharacters(in: .whitespaces).lowercased()
            if (sentEmail.isEmpty ? nil : sentEmail) != current {
                throw InlineError(.badRequest, "Change your email in Settings › Account")
            }
        }

        func trimmedOrNil(_ s: String?) -> String? {
            guard let t = s?.trimmingCharacters(in: .whitespaces) else { return nil }
            return t.isEmpty ? nil : t
        }
        var fields: [(String, String?)] = []
        if sent("display_name") { fields.append(("display_name", raw.display_name?.trimmingCharacters(in: .whitespaces))) }
        if sent("bio")          { fields.append(("bio", trimmedOrNil(raw.bio))) }
        if sent("location")     { fields.append(("location", trimmedOrNil(raw.location))) }
        if sent("job_title")    { fields.append(("job_title", trimmedOrNil(raw.job_title))) }
        if sent("company")      { fields.append(("company", trimmedOrNil(raw.company))) }
        if sent("avatar_url")   { fields.append(("avatar_url", MediaPath.storable(raw.avatar_url))) }
        if sent("cover_url")    { fields.append(("cover_url", MediaPath.storable(raw.cover_url))) }
        if sent("dob")          { fields.append(("dob", (raw.dob?.isEmpty ?? true) ? nil : raw.dob)) }
        if sent("gender")       { fields.append(("gender", raw.gender)) }
        if sent("dob_visibility") { fields.append(("dob_visibility", raw.dob_visibility)) }

        if sent("allow_friend_requests"), let allow = raw.allow_friend_requests {
            try await sdb.raw("UPDATE users SET allow_friend_requests = \(bind: allow) WHERE id = \(uuid: req.userID)").run()
        }
        if sent("show_in_suggestions"), let show = raw.show_in_suggestions {
            try await sdb.raw("UPDATE users SET show_in_suggestions = \(bind: show) WHERE id = \(uuid: req.userID)").run()
        }
        // Hobby-only details: the Work profile has experience and skills instead.
        if sent("languages") || sent("relationship_status") {
            guard mode == "hobby" else { throw InlineError(.badRequest, "Languages and relationship are on your Hobby profile only") }
            if sent("languages") {
                let langs = try cleanLanguages(raw.languages ?? [])
                try await sdb.raw("UPDATE users SET languages = \(bind: langs) WHERE id = \(uuid: req.userID)").run()
            }
            if sent("relationship_status") {
                let status = raw.relationship_status?.nilIfEmpty
                if let status, !relationshipStatuses.contains(status) { throw InlineError(.badRequest, "Invalid relationship status") }
                try await sdb.raw("UPDATE users SET relationship_status = \(bind: status) WHERE id = \(uuid: req.userID)").run()
            }
        }
        if sent("locked"), let locked = raw.locked {
            // `mode` is hobby/work by now; the column comes from this pair, never from input.
            let column = mode == "work" ? "work_locked" : "hobby_locked"
            try await sdb.raw("UPDATE users SET \(unsafeRaw: column) = \(bind: locked) WHERE id = \(uuid: req.userID)").run()
        }
        if sent("links_other_mode"), let link = raw.links_other_mode {
            // `mode` is hobby/work by now; the column comes from this pair, never from input.
            let column = mode == "work" ? "work_links_hobby" : "hobby_links_work"
            try await sdb.raw("UPDATE users SET \(unsafeRaw: column) = \(bind: link) WHERE id = \(uuid: req.userID)").run()
        }
        var interests = raw.interests
        if let picks = interests { interests = try await InterestStore.cleanPicks(picks, userID: req.userID, on: sdb) }
        _ = try await UserStore.updateProfile(
            userID: req.userID, fields: fields,
            interests: interests, skills: skills, mode: mode, on: req.db)
        await BackgroundJobs.refreshEmbedding(req, .profile, id: req.userID)

        guard let pub = try await UserStore.findById(req.userID, mode: mode, on: sdb) else {
            throw Abort(.internalServerError)
        }
        struct Priv: Decodable {
            let email: String?; let email_verified: Bool; let two_factor_enabled: Bool
            let dob: Date?; let dob_visibility: String?; let age: Int?; let has_password: Bool; let dob_changes: Int
        }
        let priv = try await sdb.raw("""
            SELECT email, (email_verified_at IS NOT NULL) AS email_verified, two_factor_enabled, dob, dob_visibility, age, dob_changes,
                   (password_hash IS NOT NULL AND password_hash <> '' AND password_hash <> 'SEED_DATA') AS has_password
            FROM users WHERE id = \(uuid: req.userID)
            """).first(decoding: Priv.self)!
        return DataResponse(data: PrivateUserObject(
            pub: pub, email: priv.email, email_verified: priv.email_verified,
            two_factor_enabled: priv.two_factor_enabled, has_password: priv.has_password,
            dob: priv.dob, dob_visibility: priv.dob_visibility, age: priv.age,
            dob_changes_left: BirthdayRules.changesLeft(used: priv.dob_changes)))
    }

    // MARK: POST /api/users/me/personas

    struct CreatePersonaBody: Content {
        var mode: String?
        var display_name: String?
        var bio: String?
        var job_title: String?
        var company: String?
        var skills: [String]?
        var interests: [String]?
    }

    static func createPersona(_ req: Request) async throws -> Response {
        let b = try req.content.decode(CreatePersonaBody.self)
        guard let mode = b.mode, ["hobby", "work"].contains(mode) else {
            throw InlineError(.badRequest, "mode must be hobby or work")
        }
        var skills: [String]?
        if mode == "work", let picks = b.skills {
            skills = try await SkillStore.cleanPicks(picks, userID: req.userID, on: req.db.sql())
        }
        let cleanSkills = skills
        let displayName = (b.display_name ?? "").trimmingCharacters(in: .whitespaces)
        guard !displayName.isEmpty else { throw InlineError(.badRequest, "display_name is required") }
        guard UserStore.displayNameFits(displayName) else { throw InlineError(.badRequest, UserStore.displayNameTooLong) }
        if let bio = b.bio, bio.count > 500 { throw InlineError(.badRequest, "bio must be at most 500 characters") }

        let sdb = req.db.sql()
        struct Setup: Decodable { let hobby_setup: Bool; let work_setup: Bool }
        guard let me = try await sdb.raw("""
            SELECT (hobby_display_name IS NOT NULL) AS hobby_setup, (work_display_name IS NOT NULL) AS work_setup
            FROM users WHERE id = \(uuid: req.userID)
            """).first(decoding: Setup.self)
        else { throw InlineError(.notFound, "User not found") }
        if (mode == "hobby" && me.hobby_setup) || (mode == "work" && me.work_setup) {
            throw InlineError(.conflict, "Persona already set up")
        }

        let bioVal = (b.bio?.trimmingCharacters(in: .whitespaces)).flatMap { $0.isEmpty ? nil : $0 }
        var interests = b.interests
        if mode == "hobby", let picks = interests {
            interests = try await InterestStore.cleanPicks(picks, userID: req.userID, on: sdb)
        }
        let cleanInterests = interests
        try await req.db.tx { t in
            if mode == "work" {
                let jt = (b.job_title?.trimmingCharacters(in: .whitespaces)).flatMap { $0.isEmpty ? nil : $0 }
                let co = (b.company?.trimmingCharacters(in: .whitespaces)).flatMap { $0.isEmpty ? nil : $0 }
                try await t.raw("""
                    UPDATE users SET work_display_name = \(bind: displayName), work_bio = \(bind: bioVal), work_deleted_at = NULL,
                      job_title = \(bind: jt), company = \(bind: co), updated_at = NOW()
                    WHERE id = \(uuid: req.userID)
                    """).run()
            } else {
                try await t.raw("""
                    UPDATE users SET hobby_display_name = \(bind: displayName), hobby_bio = \(bind: bioVal), hobby_deleted_at = NULL, updated_at = NOW()
                    WHERE id = \(uuid: req.userID)
                    """).run()
            }
            let list = mode == "work" ? cleanSkills : cleanInterests
            let table = mode == "work" ? "user_skills" : "user_interests"
            let col = mode == "work" ? "skill" : "interest"
            if let list, mode == "work" {
                // Kept skills keep their row, and so their endorsements.
                try await EndorsementStore.replaceSkills(of: req.userID, with: list, on: t)
            } else if let list {
                let clean = Array(Set(list.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }))
                try await t.raw("DELETE FROM \(unsafeRaw: table) WHERE user_id = \(uuid: req.userID)").run()
                if !clean.isEmpty {
                    try await t.raw("INSERT INTO \(unsafeRaw: table) (user_id, \(unsafeRaw: col)) SELECT \(uuid: req.userID), unnest(\(bind: clean)::text[]) ON CONFLICT DO NOTHING").run()
                }
            }
        }

        guard let user = try await UserStore.findById(req.userID, mode: mode, on: sdb) else { throw Abort(.internalServerError) }
        await BackgroundJobs.refreshEmbedding(req, .profile, id: req.userID)
        let res = try await DataResponse(data: user).encodeResponse(for: req)
        res.status = .created
        return res
    }

    // MARK: PATCH /api/users/me/default-mode

    struct DefaultModeBody: Content { var mode: String? }

    static func updateDefaultMode(_ req: Request) async throws -> StatusOK {
        guard let mode = try req.content.decode(DefaultModeBody.self).mode, ["hobby", "work"].contains(mode) else {
            throw InlineError(.badRequest, "mode must be hobby or work")
        }
        try await req.db.sql().raw("UPDATE users SET default_mode = \(bind: mode), updated_at = NOW() WHERE id = \(uuid: req.userID)").run()
        return StatusOK()
    }
}

/// Minimal "any JSON value" used only to learn which keys a PATCH body carried.
struct AnyCodableValue: Codable {
    init(from decoder: any Decoder) throws { _ = try decoder.singleValueContainer() }
    func encode(to encoder: any Encoder) throws {}
}

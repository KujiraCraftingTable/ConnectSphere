import Vapor
import SQLKit

/// Raw-SQL data access for users — the Swift port of the relevant parts of
/// `backend/src/routes/authRoutes.js` (`getUserById`) and
/// `backend/src/models/userModel.js`.
enum UserStore {

    /// Port of `getUserById` in authRoutes.js. `display_name`/`bio`/`avatar_url`/
    /// `cover_url` resolve from the `default_mode` persona; `password_hash` and
    /// `google_id` are never selected. `interests`/`skills` use `array_agg`
    /// (same sorted DISTINCT output as the Node `json_agg(DISTINCT …)`).
    static func authUser(id: String, on db: any SQLDatabase) async throws -> AuthUserObject? {
        let dn  = PersonaSQL.expr("display_name", modeRef: "u.default_mode")
        let bio = PersonaSQL.expr("bio", modeRef: "u.default_mode")
        let av  = PersonaSQL.expr("avatar_url", modeRef: "u.default_mode")
        let cv  = PersonaSQL.expr("cover_url", modeRef: "u.default_mode")

        return try await db.raw("""
            SELECT
              u.id::text AS id, u.username,
              \(unsafeRaw: dn)  AS display_name,
              \(unsafeRaw: bio) AS bio,
              u.avatar_color,
              \(unsafeRaw: av)  AS avatar_url,
              u.location, u.ward_id::text AS ward_id, u.gender, u.dob,
              u.job_title, u.company, u.phone, u.email,
              u.is_setup, u.default_mode, u.hobby_theme, u.work_theme,
              u.follower_count, u.following_count, u.post_count,
              u.created_at, u.updated_at, u.deleted_at,
              \(unsafeRaw: cv)  AS cover_url,
              u.hobby_display_name, u.hobby_bio, u.hobby_avatar_url, u.hobby_cover_url,
              u.work_display_name, u.work_bio, u.work_avatar_url, u.work_cover_url,
              u.dob_visibility, u.age,
              (u.hobby_display_name IS NOT NULL) AS hobby_setup,
              (u.work_display_name  IS NOT NULL) AS work_setup,
              (u.password_hash IS NOT NULL AND u.password_hash <> ''
               AND u.password_hash <> 'SEED_DATA') AS has_password,
              u.allow_friend_requests, u.show_in_suggestions,
              COALESCE(array_agg(DISTINCT ui.interest) FILTER (WHERE ui.interest IS NOT NULL), ARRAY[]::text[]) AS interests,
              COALESCE(array_agg(DISTINCT us.skill)    FILTER (WHERE us.skill    IS NOT NULL), ARRAY[]::text[]) AS skills
            FROM users u
            LEFT JOIN user_interests ui ON ui.user_id = u.id
            LEFT JOIN user_skills    us ON us.user_id  = u.id
            WHERE u.id = \(uuid: id)
            GROUP BY u.id
            """).first(decoding: AuthUserObject.self)
    }

    // MARK: - small lookups

    struct IdRow: Decodable { let id: String }
    struct CredRow: Decodable { let id: String; let password_hash: String?; let is_setup: Bool }

    static func findByUsername(_ username: String, on db: any SQLDatabase) async throws -> CredRow? {
        try await db.raw("SELECT id, password_hash, is_setup FROM users WHERE username = \(bind: username)")
            .first(decoding: CredRow.self)
    }

    static func usernameTaken(_ username: String, excluding userID: String? = nil, on db: any SQLDatabase) async throws -> Bool {
        if let userID {
            return try await db.raw("SELECT id FROM users WHERE username = \(bind: username) AND id <> \(uuid: userID)")
                .first(decoding: IdRow.self) != nil
        }
        return try await db.raw("SELECT id FROM users WHERE username = \(bind: username)")
            .first(decoding: IdRow.self) != nil
    }

    /// `password_hash` set and not a placeholder → the account can log in with a password.
    static func hasRealPassword(_ hash: String?) -> Bool {
        guard let hash, !hash.isEmpty, hash != "SEED_DATA" else { return false }
        return true
    }
}

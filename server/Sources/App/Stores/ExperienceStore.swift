import Vapor
import SQLKit

/// Work history (migration 056): the roles someone has held.
enum ExperienceStore {
    static let employmentTypes: Set<String> = ["full_time", "part_time", "internship", "contract", "freelance", "self_employed"]
    static let locationTypes: Set<String> = ["onsite", "hybrid", "remote"]
    static let maxPerUser = 30

    struct Experience: Content {
        var id: String
        @NullCoded var company_id: String?
        var company_name: String
        /// The company page's logo and badge, when the role links to one.
        @NullCoded var company_logo_url: String?
        var company_verified: Bool
        var title: String
        var employment_type: String
        @NullCoded var location: String?
        @NullCoded var location_type: String?
        /// "YYYY-MM".
        var start_month: String
        /// "YYYY-MM"; null while it's the current role.
        @NullCoded var end_month: String?
        @NullCoded var description: String?
    }

    /// Checked input (`ExperiencesController.validate`).
    struct Fields {
        var companyID: String?
        var companyName: String
        var title: String
        var employmentType: String
        var location: String?
        var locationType: String?
        var start: Date
        var end: Date?
        var description: String?
    }

    private static let select: SQLQueryString = """
        SELECT e.id::text AS id, e.company_id::text AS company_id, COALESCE(c.name, e.company_name) AS company_name,
          c.logo_url AS company_logo_url, COALESCE(c.is_verified, FALSE) AS company_verified,
          e.title, e.employment_type, e.location, e.location_type,
          to_char(e.start_month, 'YYYY-MM') AS start_month, to_char(e.end_month, 'YYYY-MM') AS end_month, e.description
        FROM work_experiences e
        LEFT JOIN companies c ON c.id = e.company_id
        """

    /// Current roles first, then the most recent.
    static func list(of user: String, on db: any SQLDatabase) async throws -> [Experience] {
        try await db.raw(select + """
             WHERE e.user_id = \(uuid: user)
             ORDER BY (e.end_month IS NULL) DESC, e.end_month DESC NULLS FIRST, e.start_month DESC, e.created_at DESC
            """).all(decoding: Experience.self)
    }

    static func count(of user: String, on db: any SQLDatabase) async throws -> Int {
        struct R: Decodable { let n: Int }
        return try await db.raw("SELECT COUNT(*)::int AS n FROM work_experiences WHERE user_id = \(uuid: user)")
            .first(decoding: R.self)?.n ?? 0
    }

    static func create(_ f: Fields, user: String, on db: any SQLDatabase) async throws -> String {
        struct R: Decodable { let id: String }
        return try await db.raw("""
            INSERT INTO work_experiences (user_id, company_id, company_name, title, employment_type, location, location_type,
                                          start_month, end_month, description)
            VALUES (\(uuid: user), \(uuid: f.companyID), \(bind: f.companyName), \(bind: f.title), \(bind: f.employmentType),
                    \(bind: f.location), \(bind: f.locationType), \(bind: f.start), \(bind: f.end), \(bind: f.description))
            RETURNING id::text AS id
            """).first(decoding: R.self)!.id
    }

    /// False when it isn't theirs (or doesn't exist).
    static func update(_ id: String, _ f: Fields, user: String, on db: any SQLDatabase) async throws -> Bool {
        struct R: Decodable { let id: String }
        return try await db.raw("""
            UPDATE work_experiences SET company_id = \(uuid: f.companyID), company_name = \(bind: f.companyName),
              title = \(bind: f.title), employment_type = \(bind: f.employmentType), location = \(bind: f.location),
              location_type = \(bind: f.locationType), start_month = \(bind: f.start), end_month = \(bind: f.end),
              description = \(bind: f.description), updated_at = now()
            WHERE id = \(uuid: id) AND user_id = \(uuid: user)
            RETURNING id::text AS id
            """).first(decoding: R.self) != nil
    }

    static func remove(_ id: String, user: String, on db: any SQLDatabase) async throws -> Bool {
        struct R: Decodable { let id: String }
        return try await db.raw("""
            DELETE FROM work_experiences WHERE id = \(uuid: id) AND user_id = \(uuid: user)
            RETURNING id::text AS id
            """).first(decoding: R.self) != nil
    }

    /// The current role (latest start) becomes the profile's job title and
    /// company, which cards, search and suggestions already show. With no
    /// current role they're left as the person set them.
    static func syncCurrentRole(of user: String, on db: any SQLDatabase) async throws {
        try await db.raw("""
            UPDATE users u SET job_title = cur.title, company = cur.company_name
            FROM (SELECT e.title, COALESCE(c.name, e.company_name) AS company_name
                  FROM work_experiences e LEFT JOIN companies c ON c.id = e.company_id
                  WHERE e.user_id = \(uuid: user) AND e.end_month IS NULL
                  ORDER BY e.start_month DESC, e.created_at DESC LIMIT 1) cur
            WHERE u.id = \(uuid: user)
            """).run()
    }

    /// A company page's People tab: who works there now, newest first.
    struct Person: Content {
        var id: String
        var display_name: String
        @NullCoded var avatar_url: String?
        @NullCoded var avatar_color: String?
        var title: String
        /// "YYYY-MM".
        var since: String
    }

    static func currentPeople(at company: String, limit: Int, on db: any SQLDatabase) async throws -> [Person] {
        try await db.raw("""
            SELECT DISTINCT ON (u.id) u.id::text AS id,
              \(unsafeRaw: PersonaSQL.expr("display_name", modeRef: "'work'")) AS display_name,
              COALESCE(\(unsafeRaw: PersonaSQL.expr("avatar_url", modeRef: "'work'")), u.avatar_url) AS avatar_url,
              u.avatar_color, e.title, to_char(e.start_month, 'YYYY-MM') AS since
            FROM work_experiences e JOIN users u ON u.id = e.user_id
            WHERE e.company_id = \(uuid: company) AND e.end_month IS NULL AND u.deleted_at IS NULL
            ORDER BY u.id, e.start_month DESC
            LIMIT \(bind: limit)
            """).all(decoding: Person.self)
    }
}

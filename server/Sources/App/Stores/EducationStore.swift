import Vapor
import SQLKit

/// Schools on a Hobby profile (migration 062).
enum EducationStore {
    static let schoolTypes: Set<String> = ["university", "college", "high_school", "other"]
    static let maxEntries = 10

    struct Education: Content {
        var id: String
        var school_name: String
        var school_type: String
        @NullCoded var major: String?
        @NullCoded var start_year: Int?
        @NullCoded var end_year: Int?
    }

    struct Fields {
        var schoolName: String
        var schoolType: String
        var major: String?
        var startYear: Int?
        var endYear: Int?
    }

    /// Newest first: still studying, then by when it ended / started.
    static func list(of user: String, on db: any SQLDatabase) async throws -> [Education] {
        try await db.raw("""
            SELECT id::text AS id, school_name, school_type, major, start_year, end_year FROM educations
            WHERE user_id = \(uuid: user)
            ORDER BY (end_year IS NULL) DESC, end_year DESC NULLS LAST, start_year DESC NULLS LAST, created_at DESC
            """).all(decoding: Education.self)
    }

    static func count(of user: String, on db: any SQLDatabase) async throws -> Int {
        struct N: Decodable { let n: Int }
        return try await db.raw("SELECT COUNT(*)::int AS n FROM educations WHERE user_id = \(uuid: user)")
            .first(decoding: N.self)?.n ?? 0
    }

    static func create(_ user: String, _ f: Fields, on db: any SQLDatabase) async throws {
        try await db.raw("""
            INSERT INTO educations (user_id, school_name, school_type, major, start_year, end_year)
            VALUES (\(uuid: user), \(bind: f.schoolName), \(bind: f.schoolType), \(bind: f.major),
                    \(bind: f.startYear), \(bind: f.endYear))
            """).run()
    }

    /// False when it isn't theirs.
    static func update(_ id: String, of user: String, _ f: Fields, on db: any SQLDatabase) async throws -> Bool {
        struct R: Decodable { let id: String }
        return try await db.raw("""
            UPDATE educations SET school_name = \(bind: f.schoolName), school_type = \(bind: f.schoolType),
              major = \(bind: f.major), start_year = \(bind: f.startYear), end_year = \(bind: f.endYear), updated_at = now()
            WHERE id = \(uuid: id) AND user_id = \(uuid: user) RETURNING id::text AS id
            """).first(decoding: R.self) != nil
    }

    static func remove(_ id: String, of user: String, on db: any SQLDatabase) async throws -> Bool {
        struct R: Decodable { let id: String }
        return try await db.raw("""
            DELETE FROM educations WHERE id = \(uuid: id) AND user_id = \(uuid: user) RETURNING id::text AS id
            """).first(decoding: R.self) != nil
    }
}

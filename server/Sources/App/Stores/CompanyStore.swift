import Vapor
import SQLKit

/// Company pages (migration 055): the page itself, its admins and followers.
enum CompanyStore {
    static let sizes: Set<String> = ["1-10", "11-50", "51-200", "201-500", "501-1000", "1000+"]

    /// A company as one viewer sees it.
    struct Company: Content {
        var id: String
        var name: String
        var slug: String
        @NullCoded var logo_url: String?
        @NullCoded var cover_url: String?
        @NullCoded var about: String?
        @NullCoded var industry: String?
        @NullCoded var size: String?
        @NullCoded var website: String?
        @NullCoded var headquarters: String?
        @NullCoded var founded_year: Int?
        var is_verified: Bool
        var follower_count: Int
        var created_at: Date
        var is_following: Bool
        /// "owner" / "admin" when the viewer runs the page.
        @NullCoded var my_role: String?
    }

    /// The editable fields, already checked (`CompaniesController.validate`).
    struct Fields {
        var name: String
        var logoURL: String?
        var coverURL: String?
        var about: String?
        var industry: String?
        var size: String?
        var website: String?
        var headquarters: String?
        var foundedYear: Int?
    }

    private static func select(_ viewer: String) -> SQLQueryString {
        """
        SELECT c.id::text AS id, c.name, c.slug, c.logo_url, c.cover_url, c.about, c.industry, c.size,
          c.website, c.headquarters, c.founded_year::int AS founded_year, c.is_verified, c.follower_count, c.created_at,
          EXISTS(SELECT 1 FROM company_followers f WHERE f.company_id = c.id AND f.user_id = \(uuid: viewer)) AS is_following,
          (SELECT a.role FROM company_admins a WHERE a.company_id = c.id AND a.user_id = \(uuid: viewer)) AS my_role
        FROM companies c
        """
    }

    static func byID(_ id: String, viewer: String, on db: any SQLDatabase) async throws -> Company? {
        try await db.raw(select(viewer) + " WHERE c.id = \(uuid: id)").first(decoding: Company.self)
    }

    /// Name search for pickers and Search: names starting with the text
    /// first, then containing it; verified pages ahead of others.
    static func search(_ q: String, viewer: String, limit: Int, on db: any SQLDatabase) async throws -> [Company] {
        let like = "%" + q.lowercased()
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_") + "%"
        let prefix = String(like.dropFirst())
        return try await db.raw(select(viewer) + """
             WHERE lower(c.name) LIKE \(bind: like)
             ORDER BY (lower(c.name) LIKE \(bind: prefix)) DESC, c.is_verified DESC, c.follower_count DESC, c.name
             LIMIT \(bind: limit)
            """).all(decoding: Company.self)
    }

    /// The pages `user` runs (to post jobs as a company, Phase 4).
    static func administered(by user: String, on db: any SQLDatabase) async throws -> [Company] {
        try await db.raw(select(user) + """
             WHERE EXISTS(SELECT 1 FROM company_admins a WHERE a.company_id = c.id AND a.user_id = \(uuid: user))
             ORDER BY c.name
            """).all(decoding: Company.self)
    }

    static func nameTaken(_ name: String, except id: String? = nil, on db: any SQLDatabase) async throws -> Bool {
        struct R: Decodable { let id: String }
        let q: SQLQueryString = id.map {
            "SELECT id::text AS id FROM companies WHERE lower(name) = lower(\(bind: name)) AND id <> \(uuid: $0)"
        } ?? "SELECT id::text AS id FROM companies WHERE lower(name) = lower(\(bind: name))"
        return try await db.raw(q).first(decoding: R.self) != nil
    }

    /// "FPT Software" → "fpt-software" (with a number added if taken).
    static func slug(for name: String, on db: any SQLDatabase) async throws -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en"))
            .replacingOccurrences(of: "đ", with: "d").replacingOccurrences(of: "Đ", with: "d")
        let base = String(folded.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" })
            .split(separator: "-").joined(separator: "-").prefix(100)
        let root = base.isEmpty ? "company" : String(base)
        struct R: Decodable { let n: Int }
        var candidate = root, i = 2
        while try await db.raw("SELECT COUNT(*)::int AS n FROM companies WHERE slug = \(bind: candidate)")
            .first(decoding: R.self)?.n ?? 0 > 0 {
            candidate = "\(root)-\(i)"; i += 1
        }
        return candidate
    }

    /// Creates the page with `owner` as its owner, in one transaction.
    static func create(_ f: Fields, owner: String, on db: AppDatabase) async throws -> String {
        let sdb = db.sql()
        let slug = try await slug(for: f.name, on: sdb)
        var id = ""
        try await db.tx { t in
            struct R: Decodable { let id: String }
            id = try await t.raw("""
                INSERT INTO companies (name, slug, logo_url, cover_url, about, industry, size, website, headquarters, founded_year, created_by)
                VALUES (\(bind: f.name), \(bind: slug), \(bind: f.logoURL), \(bind: f.coverURL), \(bind: f.about), \(bind: f.industry),
                        \(bind: f.size), \(bind: f.website), \(bind: f.headquarters), \(bind: f.foundedYear), \(uuid: owner))
                RETURNING id::text AS id
                """).first(decoding: R.self)!.id
            try await t.raw("INSERT INTO company_admins (company_id, user_id, role) VALUES (\(uuid: id), \(uuid: owner), 'owner')").run()
        }
        return id
    }

    static func update(_ id: String, _ f: Fields, on db: any SQLDatabase) async throws {
        try await db.raw("""
            UPDATE companies SET name = \(bind: f.name), logo_url = \(bind: f.logoURL), cover_url = \(bind: f.coverURL),
              about = \(bind: f.about), industry = \(bind: f.industry), size = \(bind: f.size), website = \(bind: f.website),
              headquarters = \(bind: f.headquarters), founded_year = \(bind: f.foundedYear), updated_at = now()
            WHERE id = \(uuid: id)
            """).run()
    }

    static func role(of user: String, in company: String, on db: any SQLDatabase) async throws -> String? {
        struct R: Decodable { let role: String }
        return try await db.raw("SELECT role FROM company_admins WHERE company_id = \(uuid: company) AND user_id = \(uuid: user)")
            .first(decoding: R.self)?.role
    }

    /// Follows or unfollows; the count moves only when the state changes.
    static func setFollowing(_ follow: Bool, company: String, user: String, on db: AppDatabase) async throws {
        try await db.tx { t in
            struct R: Decodable { let company_id: String }
            let changed: Bool
            if follow {
                changed = try await t.raw("""
                    INSERT INTO company_followers (company_id, user_id) VALUES (\(uuid: company), \(uuid: user))
                    ON CONFLICT DO NOTHING RETURNING company_id::text AS company_id
                    """).first(decoding: R.self) != nil
            } else {
                changed = try await t.raw("""
                    DELETE FROM company_followers WHERE company_id = \(uuid: company) AND user_id = \(uuid: user)
                    RETURNING company_id::text AS company_id
                    """).first(decoding: R.self) != nil
            }
            if changed {
                try await t.raw("""
                    UPDATE companies SET follower_count = GREATEST(0, follower_count \(unsafeRaw: follow ? "+" : "-") 1)
                    WHERE id = \(uuid: company)
                    """).run()
            }
        }
    }
}

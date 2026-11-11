import Vapor
import SQLKit

/// Verified HR (migration 126): who may post jobs. A person asks with a
/// company-domain email (proved by a code), tax code, website and business
/// registration PDF; the app admin reviews it by hand. One HR per tax code.
enum HRStore {
    // MARK: rules

    /// Public mail providers: an address there proves nothing about a company.
    static let freeMailDomains: Set<String> = [
        "gmail.com", "googlemail.com", "yahoo.com", "yahoo.com.vn", "ymail.com", "outlook.com", "hotmail.com",
        "live.com", "msn.com", "icloud.com", "me.com", "mac.com", "proton.me", "protonmail.com", "aol.com",
        "gmx.com", "mail.com", "zoho.com", "yandex.com", "qq.com", "163.com",
    ]
    /// How many jobs a new HR's posts wait for review before going live straight away.
    static let trialJobs = 3
    /// A job hides itself after this many reports, until the admin decides.
    static let reportsToHide = 3
    static let maxCompanyName = 100
    static let maxWebsite = 200
    static let maxEmail = 254
    static let maxCareersURL = 500
    static let maxNote = 500
    /// What the admin confirms before approving; all must be ticked.
    static let checklistItems = ["email_verified", "tax_code_registry", "name_matches_licence", "domain_matches_website"]

    /// The domain of `name@domain`, lowercased, or nil.
    static func emailDomain(_ email: String) -> String? {
        let e = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let parts = e.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, parts[1].contains("."),
              !parts[1].hasPrefix("."), !parts[1].hasSuffix("."), !e.contains(" ") else { return nil }
        return String(parts[1])
    }

    /// The website's host without `www.`, from "techviet.vn" or "https://www.techviet.vn/about".
    static func websiteHost(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let withScheme = t.hasPrefix("http://") || t.hasPrefix("https://") ? t : "https://" + t
        guard let host = URLComponents(string: withScheme)?.host, host.contains("."), !host.contains(" ") else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// The email is on the website's domain (or a subdomain of it, either way:
    /// hr@techviet.vn for careers.techviet.vn and hr@mail.techviet.vn for techviet.vn).
    static func sameCompanyDomain(email: String, website: String) -> Bool {
        guard let d = emailDomain(email), let h = websiteHost(website) else { return false }
        return d == h || d.hasSuffix("." + h) || h.hasSuffix("." + d)
    }

    /// Vietnamese tax code: 10 digits, or 10 + 3 for a branch ("0101234567-001").
    static func validTaxCode(_ s: String) -> Bool {
        s.range(of: #"^\d{10}(-?\d{3})?$"#, options: .regularExpression) != nil
    }

    /// The same code written with or without the branch dash.
    static func normalizedTaxCode(_ s: String) -> String {
        let digits = s.filter(\.isNumber)
        return digits.count == 13 ? String(digits.prefix(10)) + "-" + String(digits.suffix(3)) : digits
    }

    // MARK: reads

    struct Recruiter: Content {
        var company_name: String
        var tax_code: String
        @NullCoded var company_id: String?
        var trial_left: Int
        var verified_at: Date
    }

    static func recruiter(_ user: String, on db: any SQLDatabase) async throws -> Recruiter? {
        try await db.raw("""
            SELECT company_name, tax_code, company_id::text AS company_id, trial_left, verified_at
            FROM recruiters WHERE user_id = \(uuid: user)
            """).first(decoding: Recruiter.self)
    }

    /// What the app shows on "Become HR": the latest request and, once approved, the company.
    struct MyStatus: Content {
        /// none | pending | approved | rejected | revoked
        var status: String
        @NullCoded var company_name: String?
        @NullCoded var review_note: String?
        @NullCoded var trial_left: Int?
        @NullCoded var submitted_at: Date?
    }

    static func status(of user: String, on db: any SQLDatabase) async throws -> MyStatus {
        if let r = try await recruiter(user, on: db) {
            return MyStatus(status: "approved", company_name: r.company_name, review_note: nil,
                            trial_left: r.trial_left, submitted_at: nil)
        }
        struct R: Decodable { let status: String; let company_name: String; let review_note: String?; let created_at: Date }
        guard let last = try await db.raw("""
            SELECT status, company_name, review_note, created_at FROM hr_requests
            WHERE user_id = \(uuid: user) ORDER BY created_at DESC LIMIT 1
            """).first(decoding: R.self) else {
            return MyStatus(status: "none", company_name: nil, review_note: nil, trial_left: nil, submitted_at: nil)
        }
        // An approved request whose recruiter row is gone was revoked.
        let status = last.status == "approved" ? "revoked" : last.status
        return MyStatus(status: status, company_name: last.company_name, review_note: last.review_note,
                        trial_left: nil, submitted_at: last.created_at)
    }

    static func hasPending(_ user: String, on db: any SQLDatabase) async throws -> Bool {
        struct R: Decodable { let x: Int }
        return try await db.raw("SELECT 1 AS x FROM hr_requests WHERE user_id = \(uuid: user) AND status = 'pending'")
            .first(decoding: R.self) != nil
    }

    struct NewRequest {
        var user: String; var companyName: String; var taxCode: String; var website: String
        var workEmail: String; var licencePath: String
    }

    static func create(_ r: NewRequest, on db: any SQLDatabase) async throws -> String {
        struct R: Decodable { let id: String }
        return try await db.raw("""
            INSERT INTO hr_requests (user_id, company_name, tax_code, website, work_email, licence_path)
            VALUES (\(uuid: r.user), \(bind: r.companyName), \(bind: r.taxCode), \(bind: r.website),
                    \(bind: r.workEmail), \(bind: r.licencePath))
            RETURNING id::text AS id
            """).first(decoding: R.self)!.id
    }

    // MARK: admin queue

    struct Person: Content {
        var id: String
        var username: String
        var display_name: String
        @NullCoded var avatar_url: String?
        @NullCoded var avatar_color: String?
    }

    struct Request: Content {
        var id: String
        var status: String
        var company_name: String
        var tax_code: String
        var website: String
        var work_email: String
        var licence_path: String
        @NullCoded var review_note: String?
        @NullCoded var checklist: [String: Bool]?
        var created_at: Date
        @NullCoded var decided_at: Date?
        var person: Person
        /// "@username" of the person already HR for this tax code: approving is refused.
        @NullCoded var conflict_with: String?
    }

    private struct Row: Decodable {
        let id: String; let status: String; let company_name: String; let tax_code: String; let website: String
        let work_email: String; let licence_path: String; let review_note: String?; let checklist: String?
        let created_at: Date; let decided_at: Date?
        let user_id: String; let username: String; let display_name: String; let avatar_url: String?; let avatar_color: String?
        let conflict_with: String?
    }

    private static let select: SQLQueryString = """
        SELECT h.id::text AS id, h.status, h.company_name, h.tax_code, h.website, h.work_email, h.licence_path,
          h.review_note, h.checklist::text AS checklist, h.created_at, h.decided_at,
          u.id::text AS user_id, u.username,
          COALESCE(u.work_display_name, u.username) AS display_name,
          COALESCE(u.work_avatar_url, u.avatar_url) AS avatar_url, u.avatar_color,
          (SELECT '@' || cu.username FROM recruiters r JOIN users cu ON cu.id = r.user_id
            WHERE r.tax_code = h.tax_code AND r.user_id <> h.user_id) AS conflict_with
        FROM hr_requests h JOIN users u ON u.id = h.user_id
        """

    private static func request(_ r: Row) -> Request {
        let checklist = r.checklist.flatMap { try? JSONDecoder().decode([String: Bool].self, from: Data($0.utf8)) }
        return Request(id: r.id, status: r.status, company_name: r.company_name, tax_code: r.tax_code, website: r.website,
                       work_email: r.work_email, licence_path: r.licence_path, review_note: r.review_note,
                       checklist: checklist, created_at: r.created_at, decided_at: r.decided_at,
                       person: Person(id: r.user_id, username: r.username, display_name: r.display_name,
                                      avatar_url: r.avatar_url, avatar_color: r.avatar_color),
                       conflict_with: r.conflict_with)
    }

    static func requests(status: String, limit: Int, offset: Int, on db: any SQLDatabase) async throws -> [Request] {
        // Pending: oldest first (a queue); decided: newest first (a history).
        let order: SQLQueryString = status == "pending" ? "h.created_at ASC" : "h.decided_at DESC NULLS LAST"
        return try await db.raw(select + " WHERE h.status = \(bind: status) ORDER BY " + order
                                + " LIMIT \(bind: limit) OFFSET \(bind: offset)")
            .all(decoding: Row.self).map(request)
    }

    static func request(_ id: String, on db: any SQLDatabase) async throws -> Request? {
        try await db.raw(select + " WHERE h.id = \(uuid: id)").first(decoding: Row.self).map(request)
    }

    /// Approves (making the person HR) or rejects a pending request. nil when
    /// it isn't pending any more.
    static func decide(_ id: String, approve: Bool, checklist: [String: Bool], note: String?, reviewer: String,
                       on db: AppDatabase) async throws -> Request? {
        guard let req = try await request(id, on: db.sql()), req.status == "pending" else { return nil }
        let checklistJSON = String(data: try JSONEncoder().encode(checklist), encoding: .utf8)
        try await db.tx { t in
            try await t.raw("""
                UPDATE hr_requests SET status = \(bind: approve ? "approved" : "rejected"),
                  checklist = \(bind: checklistJSON)::jsonb, review_note = \(bind: note),
                  reviewed_by = \(uuid: reviewer), decided_at = NOW()
                WHERE id = \(uuid: id)
                """).run()
            guard approve else { return }
            // The Official company page of the same name, when there is one, so
            // job cards show its logo. Only Official pages: a page's admins can
            // see the applicants of its jobs, and anyone can make a page.
            try await t.raw("""
                INSERT INTO recruiters (user_id, request_id, company_name, tax_code, company_id, trial_left)
                VALUES (\(uuid: req.person.id), \(uuid: id), \(bind: req.company_name), \(bind: req.tax_code),
                        (SELECT id FROM companies WHERE lower(name) = lower(\(bind: req.company_name)) AND is_verified LIMIT 1),
                        \(bind: trialJobs))
                """).run()
        }
        return try await request(id, on: db.sql())
    }

    /// Takes HR away: their job posts go (applications with them). Returns
    /// who had applied, with a job title each, so they can be told. nil when not HR.
    static func revoke(_ user: String, note: String?, on db: AppDatabase) async throws -> [String: String]? {
        guard try await recruiter(user, on: db.sql()) != nil else { return nil }
        struct A: Decodable { let applicant_id: String; let title: String }
        let applied = try await db.sql().raw("""
            SELECT ja.applicant_id::text AS applicant_id, jp.title
            FROM job_applications ja JOIN job_posts jp ON jp.id = ja.job_id JOIN posts p ON p.id = jp.post_id
            WHERE p.author_id = \(uuid: user) AND p.post_type = 'job'
            """).all(decoding: A.self)
        try await db.tx { t in
            try await t.raw("DELETE FROM recruiters WHERE user_id = \(uuid: user)").run()
            try await t.raw("""
                UPDATE hr_requests SET status = 'revoked', review_note = COALESCE(\(bind: note), review_note), decided_at = NOW()
                WHERE user_id = \(uuid: user) AND status = 'approved'
                """).run()
            // Cascades to job_posts, applications, saves.
            try await t.raw("DELETE FROM posts WHERE author_id = \(uuid: user) AND post_type = 'job'").run()
        }
        var titles: [String: String] = [:]
        for a in applied where titles[a.applicant_id] == nil { titles[a.applicant_id] = a.title }
        return titles
    }

    // MARK: trial review of a new HR's jobs

    struct PendingJob: Content {
        var post_id: String
        var title: String
        @NullCoded var company: String?
        @NullCoded var location: String?
        @NullCoded var salary_range: String?
        @NullCoded var careers_url: String?
        @NullCoded var description: String?
        var created_at: Date
        var person: Person
    }

    static func pendingJobs(limit: Int, offset: Int, on db: any SQLDatabase) async throws -> [PendingJob] {
        struct R: Decodable {
            let post_id: String; let title: String; let company: String?; let location: String?; let salary_range: String?
            let careers_url: String?; let description: String?; let created_at: Date
            let user_id: String; let username: String; let display_name: String; let avatar_url: String?; let avatar_color: String?
        }
        return try await db.raw("""
            SELECT p.id::text AS post_id, jp.title, jp.company, jp.location, jp.salary_range, jp.careers_url,
              p.content AS description, p.created_at,
              u.id::text AS user_id, u.username, COALESCE(u.work_display_name, u.username) AS display_name,
              COALESCE(u.work_avatar_url, u.avatar_url) AS avatar_url, u.avatar_color
            FROM posts p JOIN job_posts jp ON jp.post_id = p.id JOIN users u ON u.id = p.author_id
            WHERE p.post_type = 'job' AND p.status = 'pending' AND p.community_id IS NULL
            ORDER BY p.created_at ASC LIMIT \(bind: limit) OFFSET \(bind: offset)
            """).all(decoding: R.self).map {
                PendingJob(post_id: $0.post_id, title: $0.title, company: $0.company, location: $0.location,
                           salary_range: $0.salary_range, careers_url: $0.careers_url, description: $0.description,
                           created_at: $0.created_at,
                           person: Person(id: $0.user_id, username: $0.username, display_name: $0.display_name,
                                          avatar_url: $0.avatar_url, avatar_color: $0.avatar_color))
            }
    }

    struct DecidedJob: Decodable {
        let author_id: String; let mode: String; let content: String?; let title: String; let job_id: String
    }

    /// Approve (it goes live as new and uses up one trial job) or decline.
    /// nil when the job isn't waiting for review.
    static func decideJob(_ postID: String, approve: Bool, on db: AppDatabase) async throws -> DecidedJob? {
        var decided: DecidedJob?
        try await db.tx { t in
            decided = try await t.raw("""
                UPDATE posts p SET status = \(bind: approve ? "posted" : "declined")::post_status,
                  created_at = CASE WHEN \(bind: approve) THEN NOW() ELSE p.created_at END
                FROM job_posts jp
                WHERE p.id = \(uuid: postID) AND jp.post_id = p.id AND p.post_type = 'job'
                  AND p.status = 'pending' AND p.community_id IS NULL
                RETURNING p.author_id::text AS author_id, p.mode, p.content, jp.title, jp.id::text AS job_id
                """).first(decoding: DecidedJob.self)
            if let d = decided, approve {
                try await t.raw("""
                    UPDATE recruiters SET trial_left = GREATEST(0, trial_left - 1) WHERE user_id = \(uuid: d.author_id)
                    """).run()
            }
        }
        return decided
    }

    // MARK: reports

    /// After a report on a job post: hide it once enough reports are in.
    static func hideIfReported(postID: String, caseID: String, on db: any SQLDatabase) async throws {
        try await db.raw("""
            UPDATE job_posts SET hidden_at = NOW()
            WHERE post_id = \(uuid: postID) AND hidden_at IS NULL
              AND (SELECT report_count FROM moderation_cases WHERE id = \(uuid: caseID)) >= \(bind: reportsToHide)
            """).run()
    }

    /// The admin kept the job after its reports: it shows again.
    static func unhide(postID: String, on db: any SQLDatabase) async throws {
        try await db.raw("UPDATE job_posts SET hidden_at = NULL WHERE post_id = \(uuid: postID)").run()
    }
}

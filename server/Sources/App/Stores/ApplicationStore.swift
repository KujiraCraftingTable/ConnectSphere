import Vapor
import SQLKit

/// Easy Apply (migration 059): applications and their status timeline.
enum ApplicationStore {
    /// Statuses a manager can move an application to.
    static let managerStatuses: Set<String> = ["viewed", "shortlisted", "rejected", "hired"]
    static let maxNoteLength = 1000

    struct Event: Content {
        var status: String
        var created_at: Date
    }

    struct Person: Content {
        var id: String
        var display_name: String
        @NullCoded var avatar_url: String?
        @NullCoded var avatar_color: String?
        @NullCoded var job_title: String?
        @NullCoded var location: String?
    }

    /// One application, as its applicant or the job's managers see it.
    struct Application: Content {
        var id: String
        var job_id: String
        var job_title: String
        @NullCoded var company_name: String?
        @NullCoded var company_logo_url: String?
        var status: String
        @NullCoded var note: String?
        @NullCoded var cv_url: String?
        var created_at: Date
        var updated_at: Date
        var events: [Event]
        var applicant: Person
        /// How the applicant fits the job (managers' view).
        @NullCoded var match: JobBoardStore.Match? = nil
    }

    /// The job's poster, or an admin of the company it's posted as.
    static func canManage(job: String, user: String, on db: any SQLDatabase) async throws -> Bool {
        struct R: Decodable { let ok: Bool }
        return try await db.raw("""
            SELECT EXISTS(SELECT 1 FROM job_posts jp JOIN posts p ON p.id = jp.post_id
              WHERE jp.id = \(uuid: job) AND (p.author_id = \(uuid: user)
                OR EXISTS(SELECT 1 FROM company_admins ca WHERE ca.company_id = jp.company_id AND ca.user_id = \(uuid: user)))) AS ok
            """).first(decoding: R.self)?.ok ?? false
    }

    /// Who hears about a new applicant: the poster and the company's admins.
    static func managers(of job: String, on db: any SQLDatabase) async throws -> [String] {
        struct R: Decodable { let id: String }
        return try await db.raw("""
            SELECT p.author_id::text AS id FROM job_posts jp JOIN posts p ON p.id = jp.post_id WHERE jp.id = \(uuid: job)
            UNION
            SELECT ca.user_id::text FROM job_posts jp JOIN company_admins ca ON ca.company_id = jp.company_id WHERE jp.id = \(uuid: job)
            """).all(decoding: R.self).map(\.id)
    }

    /// The new application's id, or nil when they'd already applied.
    static func apply(job: String, applicant: String, note: String?, cvURL: String?, on db: AppDatabase) async throws -> String? {
        var id: String?
        try await db.tx { t in
            struct R: Decodable { let id: String }
            id = try await t.raw("""
                INSERT INTO job_applications (job_id, applicant_id, note, cv_url)
                VALUES (\(uuid: job), \(uuid: applicant), \(bind: note), \(bind: cvURL))
                ON CONFLICT (job_id, applicant_id) DO NOTHING RETURNING id::text AS id
                """).first(decoding: R.self)?.id
            if let id {
                try await t.raw("INSERT INTO application_events (application_id, status) VALUES (\(uuid: id), 'applied')").run()
            }
        }
        return id
    }

    private static let select: SQLQueryString = """
        SELECT a.id::text AS id, jp.id::text AS job_id, jp.title AS job_title, COALESCE(c.name, jp.company) AS company_name,
          c.logo_url AS company_logo_url, a.status, a.note, a.cv_url, a.created_at, a.updated_at,
          COALESCE((SELECT json_agg(json_build_object('status', e.status, 'created_at', e.created_at) ORDER BY e.created_at)
                    FROM application_events e WHERE e.application_id = a.id), '[]')::text AS events,
          u.id::text AS applicant_id, \(unsafeRaw: PersonaSQL.expr("display_name", modeRef: "'work'")) AS applicant_name,
          COALESCE(\(unsafeRaw: PersonaSQL.expr("avatar_url", modeRef: "'work'")), u.avatar_url) AS applicant_avatar,
          u.avatar_color AS applicant_color, u.job_title AS applicant_title, u.location AS applicant_location
        FROM job_applications a
        JOIN job_posts jp ON jp.id = a.job_id
        JOIN users u ON u.id = a.applicant_id
        LEFT JOIN companies c ON c.id = jp.company_id
        """

    private struct Row: Decodable {
        let id: String; let job_id: String; let job_title: String; let company_name: String?; let company_logo_url: String?
        let status: String; let note: String?; let cv_url: String?; let created_at: Date; let updated_at: Date
        let events: String; let applicant_id: String; let applicant_name: String; let applicant_avatar: String?
        let applicant_color: String?; let applicant_title: String?; let applicant_location: String?
    }

    private static func map(_ r: Row) -> Application {
        let events = (try? JSONCoding.makeDecoder().decode([Event].self, from: Data(r.events.utf8))) ?? []
        return Application(
            id: r.id, job_id: r.job_id, job_title: r.job_title, company_name: r.company_name,
            company_logo_url: r.company_logo_url, status: r.status, note: r.note, cv_url: r.cv_url,
            created_at: r.created_at, updated_at: r.updated_at, events: events,
            applicant: Person(id: r.applicant_id, display_name: r.applicant_name, avatar_url: r.applicant_avatar,
                              avatar_color: r.applicant_color, job_title: r.applicant_title, location: r.applicant_location))
    }

    /// Your applications, newest first.
    static func mine(_ user: String, on db: any SQLDatabase) async throws -> [Application] {
        try await db.raw(select + " WHERE a.applicant_id = \(uuid: user) ORDER BY a.created_at DESC")
            .all(decoding: Row.self).map(map)
    }

    /// A job's applicants, newest first, each with how they fit it.
    static func forJob(_ job: String, on db: any SQLDatabase) async throws -> [Application] {
        var list = try await db.raw(select + " WHERE a.job_id = \(uuid: job) ORDER BY a.created_at DESC LIMIT 200")
            .all(decoding: Row.self).map(map)
        for i in list.indices {
            list[i].match = try await JobBoardStore.byID(job, viewer: list[i].applicant.id, on: db)?.match
        }
        return list
    }

    static func byID(_ id: String, on db: any SQLDatabase) async throws -> Application? {
        try await db.raw(select + " WHERE a.id = \(uuid: id)").first(decoding: Row.self).map(map)
    }

    /// Moves an application along and records the step. False when it
    /// was already there.
    static func setStatus(_ id: String, to status: String, on db: AppDatabase) async throws -> Bool {
        var changed = false
        try await db.tx { t in
            struct R: Decodable { let id: String }
            changed = try await t.raw("""
                UPDATE job_applications SET status = \(bind: status), updated_at = now()
                WHERE id = \(uuid: id) AND status <> \(bind: status) RETURNING id::text AS id
                """).first(decoding: R.self) != nil
            if changed {
                try await t.raw("INSERT INTO application_events (application_id, status) VALUES (\(uuid: id), \(bind: status))").run()
            }
        }
        return changed
    }
}

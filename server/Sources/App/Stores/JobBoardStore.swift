import Vapor
import SQLKit
import Foundation

/// The Jobs tab (Work mode): open jobs to browse, search, save and get
/// recommended, each with how well it matches the viewer.
enum JobBoardStore {
    struct Poster: Content {
        var id: String
        var display_name: String
        @NullCoded var avatar_url: String?
        @NullCoded var avatar_color: String?
        @NullCoded var job_title: String?
        /// The company they're verified HR for (migration 126).
        @NullCoded var hr_company: String? = nil
    }

    /// Why and how well a job fits the viewer.
    struct Match: Content {
        /// 0…1.
        var score: Double
        var matched_skills: [String]
        var missing_skills: [String]
        /// skills | company | remote | near | title | profile
        var reason: String
    }

    /// A job this close (km, ward centre to ward centre) counts as near.
    static let nearKm = 10.0

    struct Listing: Content {
        var id: String
        var post_id: String
        var title: String
        @NullCoded var company_name: String?
        @NullCoded var company_id: String?
        @NullCoded var company_logo_url: String?
        var company_verified: Bool
        @NullCoded var location: String?
        @NullCoded var employment_type: String?
        @NullCoded var work_format: String?
        @NullCoded var level: String?
        @NullCoded var salary_min: Int?
        @NullCoded var salary_max: Int?
        var salary_negotiable: Bool
        @NullCoded var salary_range: String?
        /// Straight-line km between the viewer's ward and the job's, rounded up
        /// to 5 (ward-sized precision); nil when either has no ward.
        @NullCoded var distance_km: Int? = nil
        /// The company's job description PDF (`/uploads/jd/…`), if attached.
        @NullCoded var jd_path: String? = nil
        /// "YYYY-MM-DD".
        @NullCoded var application_deadline: String?
        var created_at: Date
        @NullCoded var description: String?
        /// The job on the company's own careers page, for applicants to check.
        @NullCoded var careers_url: String? = nil
        /// 'plain' or 'markdown' (the job post's content_format).
        var description_format: String? = nil
        var skills: [String]
        var saved: Bool
        var interested_count: Int
        var poster: Poster
        var is_mine: Bool
        var match: Match
        /// The viewer's application status, if they applied.
        @NullCoded var application_status: String? = nil
        /// For the job's poster / company admins only.
        @NullCoded var applicant_count: Int? = nil
    }

    struct Row: Decodable {
        let id: String; let post_id: String; let title: String
        let company_name: String?; let company_id: String?; let company_logo_url: String?; let company_verified: Bool
        let location: String?; let employment_type: String?; let work_format: String?; let level: String?
        let salary_min: Int?; let salary_max: Int?; let salary_negotiable: Bool?; let salary_range: String?; let application_deadline: String?
        let created_at: Date; let description: String?; let careers_url: String?; let description_format: String?; let skills: String; let saved: Bool; let interested_count: Int
        let poster_id: String; let poster_name: String; let poster_avatar: String?; let poster_color: String?
        let poster_title: String?; let poster_hr_company: String?; let followed_company: Bool; let semantic: Double
        let distance_km: Double?
        let jd_path: String?
        let application_status: String?; let applicant_count: Int?
    }

    /// Open Work-mode jobs the viewer may see (the feed's visibility rules).
    private static func base(_ viewer: String, semantic: Bool) -> SQLQueryString {
        let sem: SQLQueryString = semantic ? """
            COALESCE((SELECT (1 - (pc.embedding <=> pr.embedding))::float
              FROM user_embedding_chunks pc, user_embedding_chunks pr
              WHERE pc.source_type = 'post' AND pc.source_id = p.id AND pc.chunk_index = 0
                AND pr.user_id = \(uuid: viewer) AND pr.source_type = 'user_profile' AND pr.chunk_index = 0 LIMIT 1), 0)::float
            """ : "0::float"
        let all = PostStore.FeedFilters(mode: "work", authorID: nil, tag: nil, search: nil, connectionsOnly: false, limit: 0, offset: 0)
        return """
            SELECT jp.id::text AS id, p.id::text AS post_id, jp.title, COALESCE(jc.name, jp.company) AS company_name,
              jp.company_id::text AS company_id, jc.logo_url AS company_logo_url, COALESCE(jc.is_verified, FALSE) AS company_verified,
              jp.location, jp.employment_type, jp.work_format, jp.level, jp.salary_min, jp.salary_max, jp.salary_negotiable, jp.salary_range, jp.jd_path,
              to_char(jp.application_deadline, 'YYYY-MM-DD') AS application_deadline, p.created_at, p.content AS description, jp.careers_url, p.content_format AS description_format,
              COALESCE((SELECT json_agg(js.skill ORDER BY js.skill) FROM job_skills js WHERE js.job_id = jp.id), '[]')::text AS skills,
              EXISTS(SELECT 1 FROM job_interests ji WHERE ji.job_id = jp.id AND ji.user_id = \(uuid: viewer)) AS saved,
              jp.interested_count,
              u.id::text AS poster_id, \(unsafeRaw: PersonaSQL.expr("display_name", modeRef: "'work'")) AS poster_name,
              COALESCE(\(unsafeRaw: PersonaSQL.expr("avatar_url", modeRef: "'work'")), u.avatar_url) AS poster_avatar,
              u.avatar_color AS poster_color, u.job_title AS poster_title,
              (SELECT r.company_name FROM recruiters r WHERE r.user_id = u.id) AS poster_hr_company,
              EXISTS(SELECT 1 FROM company_followers f WHERE f.company_id = jp.company_id AND f.user_id = \(uuid: viewer)) AS followed_company,
              \(sem) AS semantic,
              \(distanceSQL(viewer)) AS distance_km,
              (SELECT ja.status FROM job_applications ja WHERE ja.job_id = jp.id AND ja.applicant_id = \(uuid: viewer)) AS application_status,
              CASE WHEN p.author_id = \(uuid: viewer)
                     OR EXISTS(SELECT 1 FROM company_admins ca WHERE ca.company_id = jp.company_id AND ca.user_id = \(uuid: viewer))
                   THEN (SELECT COUNT(*)::int FROM job_applications ja2 WHERE ja2.job_id = jp.id) END AS applicant_count
            FROM job_posts jp
            JOIN posts p ON p.id = jp.post_id
            JOIN users u ON u.id = p.author_id
            LEFT JOIN companies jc ON jc.id = jp.company_id
            LEFT JOIN vn_wards jw ON jw.id = jp.ward_id
            """ + " " + PostStore.feedWhere(viewer, all) + """
             AND p.post_type = 'job' AND (jp.application_deadline IS NULL OR jp.application_deadline >= CURRENT_DATE)
            """
    }

    /// Km from the viewer's ward centre to the job's (`jw`), NULL when either
    /// has none. Haversine like people search (`SearchStore.kmToWard`).
    static func distanceSQL(_ viewer: String) -> SQLQueryString {
        """
        (SELECT 6371 * acos(LEAST(1.0, cos(radians(vw.lat)) * cos(radians(jw.lat))
           * cos(radians(jw.lng) - radians(vw.lng)) + sin(radians(vw.lat)) * sin(radians(jw.lat))))
         FROM users vu JOIN vn_wards vw ON vw.id = vu.ward_id
         -- LEAST skips NULLs, so a job without a ward (remote) would read as 0 km.
         WHERE vu.id = \(uuid: viewer) AND jw.id IS NOT NULL)
        """
    }

    /// What a job is matched against: the viewer's skills and titles. Place is
    /// the ward distance on each row (`distance_km`).
    struct Viewer {
        var skills: Set<String> = []
        var titleWords: Set<String> = []
    }

    static func viewerContext(_ viewer: String, on db: any SQLDatabase) async throws -> Viewer {
        struct R: Decodable { let skills: String; let titles: String }
        guard let r = try await db.raw("""
            SELECT COALESCE((SELECT json_agg(skill) FROM user_skills WHERE user_id = u.id), '[]')::text AS skills,
              COALESCE((SELECT json_agg(title) FROM work_experiences WHERE user_id = u.id), '[]')::text || '' AS titles
            FROM users u WHERE u.id = \(uuid: viewer)
            """).first(decoding: R.self) else { return Viewer() }
        struct T: Decodable { let job_title: String? }
        let jobTitle = try await db.raw("SELECT job_title FROM users WHERE id = \(uuid: viewer)").first(decoding: T.self)?.job_title
        let dec = JSONDecoder()
        let skills = (try? dec.decode([String].self, from: Data(r.skills.utf8))) ?? []
        let titles = ((try? dec.decode([String].self, from: Data(r.titles.utf8))) ?? []) + [jobTitle].compactMap { $0 }
        return Viewer(skills: Set(skills.map(normalize)),
                      titleWords: Set(titles.flatMap(words)))
    }

    /// "React.js" ~ "reactjs", "C#" stays "c#".
    static func normalize(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .filter { $0.isLetter || $0.isNumber || $0 == "+" || $0 == "#" }
    }

    /// Meaningful words (3+ letters, not filler) for title / place overlap.
    static func words(_ s: String) -> [String] {
        let stop: Set<String> = ["the", "and", "for", "with", "city", "thanh", "pho", "tinh", "quan"]
        return s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init).filter { $0.count >= 3 && !stop.contains($0) }
    }

    /// The score and the reason shown on the card.
    static func match(_ r: Row, skills jobSkills: [String], viewer v: Viewer, now: Date = Date()) -> Match {
        let matched = jobSkills.filter { v.skills.contains(normalize($0)) }
        let missing = jobSkills.filter { !v.skills.contains(normalize($0)) }
        let skillScore = jobSkills.isEmpty ? 0.3 : Double(matched.count) / Double(jobSkills.count)
        let titleHit = !Set(words(r.title)).isDisjoint(with: v.titleWords)
        let remote = r.work_format == "remote"
        let near = r.distance_km.map { $0 <= nearKm } ?? false
        let days = max(0, now.timeIntervalSince(r.created_at) / 86_400)
        let score = 0.45 * max(0, min(1, r.semantic)) + 0.30 * skillScore + 0.10 * (titleHit ? 1 : 0)
            + 0.10 * (remote || near ? 1 : 0) + 0.05 * exp(-days / 14)
        let reason: String
        if !jobSkills.isEmpty && !matched.isEmpty { reason = "skills" }
        else if r.followed_company { reason = "company" }
        else if near { reason = "near" }
        else if remote { reason = "remote" }
        else if titleHit { reason = "title" }
        else { reason = "profile" }
        return Match(score: (score * 100).rounded() / 100, matched_skills: matched, missing_skills: missing, reason: reason)
    }

    static func listing(_ r: Row, viewer: String, context: Viewer) -> Listing {
        let skills = (try? JSONDecoder().decode([String].self, from: Data(r.skills.utf8))) ?? []
        return Listing(
            id: r.id, post_id: r.post_id, title: r.title, company_name: r.company_name, company_id: r.company_id,
            company_logo_url: r.company_logo_url, company_verified: r.company_verified, location: r.location,
            employment_type: r.employment_type, work_format: r.work_format, level: r.level,
            salary_min: r.salary_min, salary_max: r.salary_max, salary_negotiable: r.salary_negotiable ?? false, salary_range: r.salary_range,
            distance_km: r.distance_km.map { max(5, Int((($0) / 5).rounded(.up)) * 5) }, jd_path: r.jd_path,
            application_deadline: r.application_deadline, created_at: r.created_at, description: r.description, careers_url: r.careers_url, description_format: r.description_format,
            skills: skills, saved: r.saved, interested_count: r.interested_count,
            poster: Poster(id: r.poster_id, display_name: r.poster_name, avatar_url: r.poster_avatar,
                           avatar_color: r.poster_color, job_title: r.poster_title, hr_company: r.poster_hr_company),
            is_mine: r.poster_id.lowercased() == viewer.lowercased(),
            match: match(r, skills: skills, viewer: context),
            application_status: r.application_status, applicant_count: r.applicant_count)
    }

    // MARK: lists

    struct Filters {
        var q: String?
        var location: String?
        var employmentType: String?
        var workFormat: String?
        var level: String?
        var salaryMin: Int?
        /// Within this many km of the viewer's ward (5 km steps, see SearchStore.radiusStepsKm).
        var radiusKm: Double?
        var companyID: String?
        var savedOnly = false
        var limit = 30
        var offset = 0
    }

    /// Newest first, narrowed by the filters.
    static func search(_ f: Filters, viewer: String, on db: any SQLDatabase) async throws -> [Listing] {
        var q = base(viewer, semantic: false)
        if let text = f.q?.nilIfEmpty {
            let like = "%" + text.lowercased() + "%"
            q = q + """
                 AND (lower(jp.title) LIKE \(bind: like) OR lower(COALESCE(jc.name, jp.company, '')) LIKE \(bind: like)
                   OR lower(COALESCE(p.content, '')) LIKE \(bind: like)
                   OR EXISTS(SELECT 1 FROM job_skills js WHERE js.job_id = jp.id AND lower(js.skill) LIKE \(bind: like)))
                """
        }
        if let l = f.location?.nilIfEmpty { q = q + " AND lower(COALESCE(jp.location, '')) LIKE \(bind: "%" + l.lowercased() + "%")" }
        if let r = f.radiusKm { q = q + " AND \(distanceSQL(viewer)) <= \(bind: r)" }
        if let t = f.employmentType { q = q + " AND jp.employment_type = \(bind: t)" }
        if let w = f.workFormat { q = q + " AND jp.work_format = \(bind: w)" }
        if let lv = f.level { q = q + " AND jp.level = \(bind: lv)" }
        if let s = f.salaryMin { q = q + " AND COALESCE(jp.salary_max, jp.salary_min) >= \(bind: s)" }
        if let c = f.companyID { q = q + " AND jp.company_id = \(uuid: c)" }
        if f.savedOnly { q = q + " AND EXISTS(SELECT 1 FROM job_interests ji2 WHERE ji2.job_id = jp.id AND ji2.user_id = \(uuid: viewer))" }
        q = q + " ORDER BY p.created_at DESC LIMIT \(bind: f.limit) OFFSET \(bind: f.offset)"
        let rows = try await db.raw(q).all(decoding: Row.self)
        let context = try await viewerContext(viewer, on: db)
        return rows.map { listing($0, viewer: viewer, context: context) }
    }

    /// The best matches for the viewer among recent open jobs (not their own).
    static func recommended(viewer: String, limit: Int, on db: any SQLDatabase) async throws -> [Listing] {
        let q = base(viewer, semantic: true) + " AND p.author_id <> \(uuid: viewer) ORDER BY p.created_at DESC LIMIT 300"
        let rows = try await db.raw(q).all(decoding: Row.self)
        let context = try await viewerContext(viewer, on: db)
        return Array(rows.map { listing($0, viewer: viewer, context: context) }
            .sorted { $0.match.score != $1.match.score ? $0.match.score > $1.match.score : $0.created_at > $1.created_at }
            .prefix(limit))
    }

    static func byID(_ id: String, viewer: String, on db: any SQLDatabase) async throws -> Listing? {
        guard let row = try await db.raw(base(viewer, semantic: true) + " AND jp.id = \(uuid: id)").first(decoding: Row.self) else { return nil }
        return listing(row, viewer: viewer, context: try await viewerContext(viewer, on: db))
    }
}

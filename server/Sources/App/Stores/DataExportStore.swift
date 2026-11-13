import Vapor
import SQLKit

/// "Download my data", the person's own data as one JSON file (Law 91/2025
/// Art. 9: the right to a copy). Each section is one query returning a `j`
/// column; the sections are joined in SQL's own JSON so nothing is re-encoded.
/// Left out on purpose: the password hash, the Google account ID and the AI
/// embeddings (numbers derived from your text, useless to read).
enum DataExportStore {
    private static func sections(for user: String) -> [(name: String, select: SQLQueryString)] {
        let u = SQLQueryString("\(uuid: user)")
        return [
            ("account", """
                SELECT to_jsonb(x) AS j FROM (
                  SELECT u.id, username, display_name, email, gender, dob, dob_visibility, age, location,
                         w.full_name_en AS ward, bio,
                         job_title, company, default_mode, languages, relationship_status,
                         hobby_display_name, hobby_bio, work_display_name, work_bio, avatar_url, cover_url, u.created_at
                  FROM users u LEFT JOIN vn_wards w ON w.id = u.ward_id WHERE u.id = \(u)) x
                """),
            ("agreements", "SELECT to_jsonb(c) - 'id' AS j FROM user_consents c WHERE user_id = \(u)"),
            ("interests", "SELECT to_jsonb(t) AS j FROM user_interests t WHERE user_id = \(u)"),
            ("skills", "SELECT to_jsonb(t) AS j FROM user_skills t WHERE user_id = \(u)"),
            ("posts", "SELECT to_jsonb(p) - 'search_tsv' AS j FROM posts p WHERE author_id = \(u)"),
            ("comments", "SELECT to_jsonb(t) AS j FROM comments t WHERE author_id = \(u)"),
            ("post_likes", "SELECT to_jsonb(t) AS j FROM post_likes t WHERE user_id = \(u)"),
            ("stories", "SELECT to_jsonb(t) AS j FROM stories t WHERE author_id = \(u)"),
            ("highlights", "SELECT to_jsonb(t) AS j FROM highlights t WHERE user_id = \(u)"),
            ("saved_posts", "SELECT to_jsonb(t) AS j FROM saved_posts t WHERE user_id = \(u)"),
            ("messages_sent", "SELECT to_jsonb(t) AS j FROM messages t WHERE sender_id = \(u)"),
            ("connections", "SELECT to_jsonb(t) AS j FROM connections t WHERE requester_id = \(u) OR addressee_id = \(u)"),
            ("follows", "SELECT to_jsonb(t) AS j FROM follows t WHERE follower_id = \(u) OR followee_id = \(u)"),
            ("blocked_people", "SELECT to_jsonb(t) AS j FROM user_blocks t WHERE blocker_id = \(u)"),
            ("muted_words", "SELECT to_jsonb(t) AS j FROM muted_words t WHERE user_id = \(u)"),
            ("communities", "SELECT to_jsonb(t) AS j FROM community_members t WHERE user_id = \(u)"),
            ("work_experience", "SELECT to_jsonb(t) AS j FROM work_experiences t WHERE user_id = \(u)"),
            ("education", "SELECT to_jsonb(t) AS j FROM educations t WHERE user_id = \(u)"),
            ("job_applications", "SELECT to_jsonb(t) AS j FROM job_applications t WHERE applicant_id = \(u)"),
            ("searches", "SELECT to_jsonb(t) AS j FROM search_sessions t WHERE user_id = \(u)"),
        ]
    }

    /// One JSON object: `{ "exported_at": …, "account": [..], "posts": [..], … }`.
    static func json(for user: String, on db: any SQLDatabase) async throws -> String {
        struct Row: Decodable { let json: String }
        var parts = ["\"exported_at\":\"\(ISO8601DateFormatter().string(from: Date()))\""]
        for (name, select) in sections(for: user) {
            let row = try await db.raw("""
                SELECT COALESCE(jsonb_agg(q.j), '[]'::jsonb)::text AS json FROM (\(select)) q
                """).first(decoding: Row.self)
            parts.append("\"\(name)\":\(row?.json ?? "[]")")
        }
        return "{" + parts.joined(separator: ",") + "}"
    }
}

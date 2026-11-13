import Vapor
import SQLKit

/// Cases, reports and the audit log (migration 089). One open case per item:
/// every report and AI flag on it merges in, so the item is judged once.
enum ModerationStore {
    /// A reportable item: who it lands on, where it lives, and a copy of it.
    struct Target: Decodable {
        let author_id: String?
        let mode: String?
        let community_id: String?
        /// JSON text — what admins will see even if the author edits or deletes it.
        let snapshot: String
    }

    /// Finds `id` as the reporter can see it, or nil. `mode` is the persona
    /// for a `user` report (hobby / work), already validated.
    static func target(_ type: ReportTarget, _ id: String, mode: String?, reporter: String,
                       on db: any SQLDatabase) async throws -> Target? {
        let q: SQLQueryString
        switch type {
        case .post:
            q = """
                SELECT p.author_id::text AS author_id, p.mode, p.community_id::text AS community_id,
                  json_build_object('post_type', p.post_type, 'content', p.content, 'article_title', p.article_title,
                    'link_url', p.link_url, 'image_urls', p.image_urls, 'created_at', p.created_at)::text AS snapshot
                FROM posts p
                WHERE p.id = \(uuid: id) AND p.status IN ('posted', 'pending') AND p.deleted_at IS NULL
                """
        case .comment:
            q = """
                SELECT c.author_id::text AS author_id, p.mode, p.community_id::text AS community_id,
                  json_build_object('content', c.content, 'image_url', c.image_url, 'post_id', c.post_id,
                    'created_at', c.created_at)::text AS snapshot
                FROM comments c JOIN posts p ON p.id = c.post_id
                WHERE c.id = \(uuid: id) AND c.status = 'posted' AND c.deleted_at IS NULL
                """
        case .message:
            // Only someone in the chat can report it. Like WhatsApp, the report
            // carries up to 5 earlier messages from the same sender for context.
            q = """
                SELECT m.sender_id::text AS author_id, NULL::text AS mode, NULL::text AS community_id,
                  json_build_object(
                    'message', json_build_object('id', m.id, 'type', m.message_type, 'content', m.content,
                      'media_url', m.media_url, 'media_items', m.media_items, 'created_at', m.created_at),
                    'conversation_id', m.conversation_id,
                    'earlier', COALESCE((
                      SELECT json_agg(e ORDER BY e.created_at) FROM (
                        SELECT x.id, x.message_type AS type, x.content, x.media_url, x.created_at
                        FROM messages x
                        WHERE x.conversation_id = m.conversation_id AND x.sender_id = m.sender_id
                          AND x.created_at < m.created_at AND x.deleted_at IS NULL
                        ORDER BY x.created_at DESC LIMIT 5) e), '[]'::json)
                  )::text AS snapshot
                FROM messages m
                WHERE m.id = \(uuid: id) AND m.deleted_at IS NULL AND m.removed_at IS NULL
                  AND EXISTS (SELECT 1 FROM conversation_participants cp
                              WHERE cp.conversation_id = m.conversation_id AND cp.user_id = \(uuid: reporter))
                """
        case .user:
            // `mode` is hobby/work, checked by the caller — safe as a literal.
            let modeRef = "'\(mode ?? "hobby")'"
            q = """
                SELECT u.id::text AS author_id, \(unsafeRaw: modeRef)::text AS mode, NULL::text AS community_id,
                  json_build_object('username', u.username, 'display_name', \(unsafeRaw: PersonaSQL.expr("display_name", modeRef: modeRef)),
                    'bio', \(unsafeRaw: PersonaSQL.expr("bio", modeRef: modeRef)),
                    'avatar_url', \(unsafeRaw: PersonaSQL.expr("avatar_url", modeRef: modeRef)),
                    'cover_url', \(unsafeRaw: PersonaSQL.expr("cover_url", modeRef: modeRef)))::text AS snapshot
                FROM users u WHERE u.id = \(uuid: id) AND u.deleted_at IS NULL
                """
        case .community:
            q = """
                SELECT c.created_by::text AS author_id, NULL::text AS mode, c.id::text AS community_id,
                  json_build_object('name', c.name, 'description', c.description, 'type', c.type,
                    'avatar_url', c.avatar_url, 'cover_url', c.cover_url)::text AS snapshot
                FROM communities c WHERE c.id = \(uuid: id)
                """
        case .story:
            q = """
                SELECT s.author_id::text AS author_id, s.mode, NULL::text AS community_id,
                  json_build_object('image_url', s.image_url, 'created_at', s.created_at)::text AS snapshot
                FROM stories s WHERE s.id = \(uuid: id)
                """
        case .company:
            q = """
                SELECT co.created_by::text AS author_id, 'work'::text AS mode, NULL::text AS community_id,
                  json_build_object('name', co.name, 'slug', co.slug, 'about', co.about, 'website', co.website,
                    'logo_url', co.logo_url, 'cover_url', co.cover_url)::text AS snapshot
                FROM companies co WHERE co.id = \(uuid: id)
                """
        }
        return try await db.raw(q).first(decoding: Target.self)
    }

    static func hasReported(_ reporter: String, _ type: ReportTarget, _ id: String, on db: any SQLDatabase) async throws -> Bool {
        struct R: Decodable { let n: Int }
        return try await db.raw("""
            SELECT COUNT(*)::int AS n FROM content_reports
            WHERE reporter_id = \(uuid: reporter) AND target_type = \(bind: type.rawValue) AND target_id = \(uuid: id)
            """).first(decoding: R.self)!.n > 0
    }

    struct Filed: Decodable { let case_id: String; let opened: Bool }

    /// Files a report, opening the item's case or merging into the open one.
    /// One statement, so a duplicate report (23505) leaves the case untouched.
    static func fileReport(reporter: String, type: ReportTarget, id: String, target: Target,
                           reason: ModerationPolicy, detail: String?, on db: any SQLDatabase) async throws -> Filed {
        try await db.raw("""
            WITH c AS (
              INSERT INTO moderation_cases (target_type, target_id, author_id, mode, community_id, snapshot,
                                            source, policy, severity, report_count)
              VALUES (\(bind: type.rawValue), \(uuid: id), \(uuid: target.author_id), \(bind: target.mode),
                      \(uuid: target.community_id), \(bind: target.snapshot)::jsonb,
                      'report', \(bind: reason.rawValue), \(bind: reason.severity), 1)
              ON CONFLICT (target_type, target_id) WHERE status = 'open' DO UPDATE SET
                report_count = moderation_cases.report_count + 1,
                policy   = CASE WHEN EXCLUDED.severity < moderation_cases.severity THEN EXCLUDED.policy ELSE moderation_cases.policy END,
                severity = LEAST(EXCLUDED.severity, moderation_cases.severity),
                updated_at = NOW()
              RETURNING id, (xmax = 0) AS opened
            ), r AS (
              INSERT INTO content_reports (case_id, reporter_id, target_type, target_id, reason, detail)
              SELECT c.id, \(uuid: reporter), \(bind: type.rawValue), \(uuid: id), \(bind: reason.rawValue), \(bind: detail)
              FROM c
              RETURNING case_id
            )
            SELECT r.case_id::text AS case_id, c.opened FROM r JOIN c ON c.id = r.case_id
            """).first(decoding: Filed.self)!
    }

    /// A case the official account opens itself (banning a profile from it),
    /// or the item's open case when one exists already.
    static func openAdminCase(type: ReportTarget, id: String, target: Target, policy: ModerationPolicy,
                              on db: any SQLDatabase) async throws -> String {
        struct R: Decodable { let case_id: String }
        return try await db.raw("""
            INSERT INTO moderation_cases (target_type, target_id, author_id, mode, community_id, snapshot,
                                          source, policy, severity, report_count)
            VALUES (\(bind: type.rawValue), \(uuid: id), \(uuid: target.author_id), \(bind: target.mode),
                    \(uuid: target.community_id), \(bind: target.snapshot)::jsonb,
                    'admin', \(bind: policy.rawValue), \(bind: policy.severity), 0)
            ON CONFLICT (target_type, target_id) WHERE status = 'open' DO UPDATE SET
              policy = EXCLUDED.policy, severity = EXCLUDED.severity, updated_at = NOW()
            RETURNING id::text AS case_id
            """).first(decoding: R.self)!.case_id
    }

    /// A case from the automatic checks, or a verdict added to the item's open
    /// case (one a report already opened). Never counts as a report.
    static func openAutoCase(type: ReportTarget, id: String, target: Target, policy: ModerationPolicy,
                             verdict: [String: Any], on db: any SQLDatabase) async throws -> Filed {
        let json = String(decoding: try JSONSerialization.data(withJSONObject: [verdict]), as: UTF8.self)
        return try await db.raw("""
            INSERT INTO moderation_cases (target_type, target_id, author_id, mode, community_id, snapshot,
                                          source, policy, severity, report_count, ai_verdicts)
            VALUES (\(bind: type.rawValue), \(uuid: id), \(uuid: target.author_id), \(bind: target.mode),
                    \(uuid: target.community_id), \(bind: target.snapshot)::jsonb,
                    'auto', \(bind: policy.rawValue), \(bind: policy.severity), 0, \(bind: json)::jsonb)
            ON CONFLICT (target_type, target_id) WHERE status = 'open' DO UPDATE SET
              ai_verdicts = moderation_cases.ai_verdicts || EXCLUDED.ai_verdicts,
              policy   = CASE WHEN EXCLUDED.severity < moderation_cases.severity THEN EXCLUDED.policy ELSE moderation_cases.policy END,
              severity = LEAST(EXCLUDED.severity, moderation_cases.severity),
              updated_at = NOW()
            RETURNING id::text AS case_id, (xmax = 0) AS opened
            """).first(decoding: Filed.self)!
    }

    /// The community staff's own queue (community_reports) for posts in a
    /// community. Their unique key means a repeat is silently ignored.
    static func fileCommunityReport(reporter: String, postID: String, communityID: String,
                                    reason: ModerationPolicy, detail: String?, on db: any SQLDatabase) async throws {
        try await db.raw("""
            INSERT INTO community_reports (reporter_id, target_type, target_id, community_id, reason, detail)
            VALUES (\(uuid: reporter), 'post', \(uuid: postID), \(uuid: communityID),
                    \(bind: ReportRules.communityReason(reason)), \(bind: detail))
            ON CONFLICT (reporter_id, target_type, target_id) DO NOTHING
            """).run()
    }

    /// Audit log; `actor` nil means the system did it.
    static func log(caseID: String?, actor: String?, action: String, detail: [String: String] = [:],
                    on db: any SQLDatabase) async throws {
        let json = String(decoding: try JSONEncoder().encode(detail), as: UTF8.self)
        try await db.raw("""
            INSERT INTO moderation_actions (case_id, actor_id, action, detail)
            VALUES (\(uuid: caseID), \(uuid: actor), \(bind: action), \(bind: json)::jsonb)
            """).run()
    }
}

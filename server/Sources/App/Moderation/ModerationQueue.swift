import Vapor
import SQLKit

/// Read side of the admin queue: case list, one case in full, appeals.
enum ModerationQueue {
    struct Author: Content {
        var id: String; var username: String
        @NullCoded var banned_at: Date?; @NullCoded var restricted_until: Date?
        var active_strikes: Int; var past_cases: Int
    }
    struct CaseRow: Content {
        var id: String; var target_type: String; var target_id: String
        @NullCoded var mode: String?; @NullCoded var community_id: String?
        var source: String; var policy: String; var severity: Int; var report_count: Int
        var status: String; var auto_hidden: Bool
        @NullCoded var decision: String?; @NullCoded var decided_at: Date?
        var created_at: Date
        /// The post to open in the post view: the post itself, or a comment's post.
        @NullCoded var post_id: String? = nil
        @NullCoded var author: Author?
        var snapshot: JSONValue
    }
    struct ReportRow: Content {
        var id: String; var reason: String; @NullCoded var detail: String?
        var reporter_username: String; var created_at: Date
    }
    struct ActionRow: Content {
        var action: String; @NullCoded var actor_username: String?; var detail: JSONValue; var created_at: Date
    }
    struct AppealRow: Content {
        var id: String; var case_id: String; @NullCoded var message: String?; var status: String
        var created_at: Date; @NullCoded var decided_at: Date?
    }
    struct CaseDetail: Content {
        var `case`: CaseRow
        var reports: [ReportRow]
        var actions: [ActionRow]
        @NullCoded var appeal: AppealRow?
        @NullCoded var decision_note: String?
    }

    private static let caseSelect = """
        SELECT mc.id::text AS id, mc.target_type, mc.target_id::text AS target_id, mc.mode, mc.community_id::text AS community_id,
          mc.source, mc.policy, mc.severity::int AS severity, mc.report_count, mc.status, mc.auto_hidden,
          mc.decision, mc.decided_at, mc.created_at, mc.snapshot::text AS snapshot, mc.decision_note,
          CASE mc.target_type WHEN 'post' THEN mc.target_id::text
            WHEN 'comment' THEN (SELECT cm.post_id::text FROM comments cm WHERE cm.id = mc.target_id) END AS post_id,
          CASE WHEN u.id IS NULL THEN NULL ELSE json_build_object(
            'id', u.id, 'username', u.username, 'banned_at', u.banned_at, 'restricted_until', u.restricted_until,
            'active_strikes', (SELECT COUNT(*) FROM moderation_strikes s
                               WHERE s.user_id = u.id AND s.revoked_at IS NULL AND s.expires_at > NOW()),
            'past_cases', (SELECT COUNT(*) FROM moderation_cases o
                           WHERE o.author_id = u.id AND o.status = 'actioned' AND o.id <> mc.id))::text END AS author
        FROM moderation_cases mc LEFT JOIN users u ON u.id = mc.author_id
        """

    private struct Raw: Decodable {
        let id: String; let target_type: String; let target_id: String; let mode: String?; let community_id: String?
        let source: String; let policy: String; let severity: Int; let report_count: Int; let status: String
        let auto_hidden: Bool; let decision: String?; let decided_at: Date?; let created_at: Date
        let snapshot: String; let decision_note: String?; let author: String?; let post_id: String?
    }

    private static func row(_ r: Raw) throws -> CaseRow {
        let dec = JSONCoding.makeDecoder()
        return CaseRow(id: r.id, target_type: r.target_type, target_id: r.target_id, mode: r.mode, community_id: r.community_id,
                       source: r.source, policy: r.policy, severity: r.severity, report_count: r.report_count,
                       status: r.status, auto_hidden: r.auto_hidden, decision: r.decision, decided_at: r.decided_at,
                       created_at: r.created_at, post_id: r.post_id,
                       author: try r.author.map { try dec.decode(Author.self, from: Data($0.utf8)) },
                       snapshot: try JSONDecoder().decode(JSONValue.self, from: Data(r.snapshot.utf8)))
    }

    /// Open cases most urgent first: severity, then how many people reported
    /// it, then oldest. Decided cases newest first.
    static func cases(status: String, source: String?, limit: Int, offset: Int, on db: any SQLDatabase) async throws -> [CaseRow] {
        var q = SQLQueryString(stringLiteral: caseSelect) + " WHERE mc.status = \(bind: status)"
        if let source { q = q + " AND mc.source = \(bind: source)" }
        q = q + (status == "open" ? " ORDER BY mc.severity, mc.report_count DESC, mc.created_at"
                                  : " ORDER BY mc.decided_at DESC NULLS LAST")
        q = q + " LIMIT \(bind: limit) OFFSET \(bind: offset)"
        return try await db.raw(q).all(decoding: Raw.self).map(row)
    }

    static func detail(_ id: String, on db: any SQLDatabase) async throws -> CaseDetail? {
        guard let raw = try await db.raw(SQLQueryString(stringLiteral: caseSelect) + " WHERE mc.id = \(uuid: id)").first(decoding: Raw.self) else {
            return nil
        }
        // Reporters are named to admins only, never to the person reported.
        let reports = try await db.raw("""
            SELECT r.id::text AS id, r.reason, r.detail, u.username AS reporter_username, r.created_at
            FROM content_reports r JOIN users u ON u.id = r.reporter_id
            WHERE r.case_id = \(uuid: id) ORDER BY r.created_at
            """).all(decoding: ReportRow.self)
        struct A: Decodable { let action: String; let actor_username: String?; let detail: String; let created_at: Date }
        let actions = try await db.raw("""
            SELECT a.action, u.username AS actor_username, a.detail::text AS detail, a.created_at
            FROM moderation_actions a LEFT JOIN users u ON u.id = a.actor_id
            WHERE a.case_id = \(uuid: id) ORDER BY a.created_at
            """).all(decoding: A.self).map {
                ActionRow(action: $0.action, actor_username: $0.actor_username,
                          detail: try JSONDecoder().decode(JSONValue.self, from: Data($0.detail.utf8)), created_at: $0.created_at)
            }
        let appeal = try await db.raw("""
            SELECT id::text AS id, case_id::text AS case_id, message, status, created_at, decided_at
            FROM moderation_appeals WHERE case_id = \(uuid: id)
            """).first(decoding: AppealRow.self)
        return CaseDetail(case: try row(raw), reports: reports, actions: actions, appeal: appeal, decision_note: raw.decision_note)
    }

    struct AppealItem: Content { var appeal: AppealRow; var `case`: CaseRow }

    static func appeals(status: String, limit: Int, offset: Int, on db: any SQLDatabase) async throws -> [AppealItem] {
        let rows = try await db.raw("""
            SELECT id::text AS id, case_id::text AS case_id, message, status, created_at, decided_at
            FROM moderation_appeals WHERE status = \(bind: status)
            ORDER BY created_at LIMIT \(bind: limit) OFFSET \(bind: offset)
            """).all(decoding: AppealRow.self)
        var out: [AppealItem] = []
        for a in rows {
            if let raw = try await db.raw(SQLQueryString(stringLiteral: caseSelect) + " WHERE mc.id = \(uuid: a.case_id)").first(decoding: Raw.self) {
                out.append(AppealItem(appeal: a, case: try row(raw)))
            }
        }
        return out
    }
}

/// Any JSON, passed through untouched (case snapshots, audit details).
enum JSONValue: Codable, Sendable {
    case null, bool(Bool), number(Double), string(String), array([JSONValue]), object([String: JSONValue])

    init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

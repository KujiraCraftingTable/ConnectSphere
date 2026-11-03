import Vapor
import SQLKit

/// Skill endorsements (migration 057).
enum EndorsementStore {
    struct Endorser: Content {
        var id: String
        var display_name: String
        @NullCoded var avatar_url: String?
        @NullCoded var avatar_color: String?
    }

    /// A skill on someone's profile, most-endorsed first.
    struct Skill: Content {
        var id: Int
        var skill: String
        var endorsement_count: Int
        var endorsed_by_me: Bool
        /// Up to three, most recent first.
        var top_endorsers: [Endorser]
    }

    static func skills(of user: String, viewer: String, on db: any SQLDatabase) async throws -> [Skill] {
        struct Row: Decodable { let id: Int; let skill: String; let endorsement_count: Int; let endorsed_by_me: Bool; let top_endorsers: String }
        let rows = try await db.raw("""
            SELECT s.id, s.skill,
              (SELECT COUNT(*)::int FROM skill_endorsements e WHERE e.skill_id = s.id) AS endorsement_count,
              EXISTS(SELECT 1 FROM skill_endorsements e WHERE e.skill_id = s.id AND e.endorser_id = \(uuid: viewer)) AS endorsed_by_me,
              COALESCE((SELECT json_agg(x) FROM (
                SELECT u.id, \(unsafeRaw: PersonaSQL.expr("display_name", modeRef: "'work'")) AS display_name,
                  COALESCE(\(unsafeRaw: PersonaSQL.expr("avatar_url", modeRef: "'work'")), u.avatar_url) AS avatar_url,
                  u.avatar_color
                FROM skill_endorsements e JOIN users u ON u.id = e.endorser_id
                WHERE e.skill_id = s.id AND u.deleted_at IS NULL
                ORDER BY e.created_at DESC LIMIT 3) x), '[]')::text AS top_endorsers
            FROM user_skills s
            WHERE s.user_id = \(uuid: user)
            ORDER BY endorsement_count DESC, s.created_at, s.skill
            """).all(decoding: Row.self)
        let dec = JSONCoding.makeDecoder()
        return rows.map {
            Skill(id: $0.id, skill: $0.skill, endorsement_count: $0.endorsement_count, endorsed_by_me: $0.endorsed_by_me,
                  top_endorsers: (try? dec.decode([Endorser].self, from: Data($0.top_endorsers.utf8))) ?? [])
        }
    }

    /// The skill's name, if `skillID` is one of `user`'s skills.
    static func skill(_ skillID: Int, of user: String, on db: any SQLDatabase) async throws -> String? {
        struct R: Decodable { let skill: String }
        return try await db.raw("SELECT skill FROM user_skills WHERE id = \(bind: skillID) AND user_id = \(uuid: user)")
            .first(decoding: R.self)?.skill
    }

    /// Endorsing needs an accepted Work connection — the people who'd know.
    static func areWorkConnections(_ a: String, _ b: String, on db: any SQLDatabase) async throws -> Bool {
        struct R: Decodable { let ok: Bool }
        return try await db.raw("""
            SELECT EXISTS(SELECT 1 FROM connections WHERE status = 'accepted' AND mode = 'work'
              AND ((requester_id = \(uuid: a) AND addressee_id = \(uuid: b)) OR (requester_id = \(uuid: b) AND addressee_id = \(uuid: a)))) AS ok
            """).first(decoding: R.self)?.ok ?? false
    }

    /// True when this added a new endorsement (so it's worth a notification).
    static func endorse(_ skillID: Int, by endorser: String, on db: any SQLDatabase) async throws -> Bool {
        struct R: Decodable { let skill_id: Int }
        return try await db.raw("""
            INSERT INTO skill_endorsements (skill_id, endorser_id) VALUES (\(bind: skillID), \(uuid: endorser))
            ON CONFLICT DO NOTHING RETURNING skill_id
            """).first(decoding: R.self) != nil
    }

    static func unendorse(_ skillID: Int, by endorser: String, on db: any SQLDatabase) async throws {
        try await db.raw("DELETE FROM skill_endorsements WHERE skill_id = \(bind: skillID) AND endorser_id = \(uuid: endorser)").run()
    }

    /// Sets someone's skills to `wanted`, keeping the rows (and endorsements)
    /// of skills that stay; only removed ones go, only new ones are added.
    static let maxSkills = 30
    static let maxSkillLength = 50

    /// A profile's skills as they'll be stored: trimmed, blanks dropped, and
    /// "Swift" / "swift" kept once (the first spelling), in the order sent.
    /// Refuses more than 30, or one longer than 50 (the app's own limits).
    static func cleanSkills(_ list: [String]) throws -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for raw in list {
            let skill = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !skill.isEmpty, seen.insert(skill.lowercased()).inserted else { continue }
            guard skill.count <= maxSkillLength else {
                throw Abort(.badRequest, reason: "Each skill must be at most \(maxSkillLength) characters")
            }
            out.append(skill)
        }
        guard out.count <= maxSkills else { throw Abort(.badRequest, reason: "At most \(maxSkills) skills") }
        return out
    }

    static func replaceSkills(of user: String, with wanted: [String], on db: any SQLDatabase) async throws {
        let clean = try cleanSkills(wanted)
        let lowered = clean.map { $0.lowercased() }
        // A spelling change ("swift" → "Swift") renames the row rather than
        // replacing it, so its endorsements stay.
        try await db.raw("""
            DELETE FROM user_skills WHERE user_id = \(uuid: user) AND NOT (LOWER(skill) = ANY(\(bind: lowered)::text[]))
            """).run()
        try await db.raw("""
            DELETE FROM user_skills u WHERE u.user_id = \(uuid: user) AND NOT (u.skill = ANY(\(bind: clean)::text[]))
              AND EXISTS (SELECT 1 FROM user_skills d WHERE d.user_id = u.user_id AND d.id <> u.id
                          AND LOWER(d.skill) = LOWER(u.skill) AND (d.skill = ANY(\(bind: clean)::text[]) OR d.id < u.id))
            """).run()
        try await db.raw("""
            UPDATE user_skills u SET skill = w.s FROM unnest(\(bind: clean)::text[]) AS w(s)
            WHERE u.user_id = \(uuid: user) AND LOWER(u.skill) = LOWER(w.s) AND u.skill <> w.s
            """).run()
        if !clean.isEmpty {
            try await db.raw("""
                INSERT INTO user_skills (user_id, skill) SELECT \(uuid: user), unnest(\(bind: clean)::text[]) ON CONFLICT DO NOTHING
                """).run()
        }
    }
}

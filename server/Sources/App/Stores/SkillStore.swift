import Vapor
import SQLKit

/// The curated Work skill catalogue (migration 084): what the skill picker
/// offers, what a profile or job may list, and the aliases search reads
/// prompts against. A skill is stored by its English name ("React").
enum SkillStore {
    static let maxProfile = 30
    static let maxJob = 10
    /// The "Suggested for you" row, from people with a similar job title.
    static let suggestedCount = 8

    struct Entry: Content {
        var id: String
        var name_en: String
        var name_vi: String
        var category: String
        @NullCoded var parent_id: String?
        var aliases: [String]
        var pick_count: Int
    }
    struct Category: Content { var key: String; var name_en: String; var name_vi: String }

    static func entries(on db: any SQLDatabase) async throws -> [Entry] {
        try await db.raw("""
            SELECT c.id::text AS id, c.name_en, c.name_vi, c.category, c.parent_id::text AS parent_id, c.aliases,
                   (SELECT COUNT(*)::int FROM user_skills us WHERE LOWER(us.skill) = LOWER(c.name_en)) AS pick_count
            FROM skill_catalog c
            """).all(decoding: Entry.self)
    }

    static func categories(on db: any SQLDatabase) async throws -> [Category] {
        try await db.raw("SELECT key, name_en, name_vi FROM skill_categories").all(decoding: Category.self)
    }

    static func current(of userID: String, on db: any SQLDatabase) async throws -> [String] {
        struct R: Decodable { let skill: String }
        return try await db.raw("SELECT skill FROM user_skills WHERE user_id = \(uuid: userID)")
            .all(decoding: R.self).map(\.skill)
    }

    /// Checks a list about to be saved and returns it in catalogue spelling.
    /// Skills the person already had stay valid, so a profile from before the
    /// catalogue can still be edited.
    static func cleanPicks(_ items: [String], userID: String?, limit: Int = maxProfile,
                           on db: any SQLDatabase) async throws -> [String] {
        var existing = Set<String>()
        if let userID { existing = Set(try await current(of: userID, on: db)) }
        do {
            return try SkillRules.normalize(items, entries: try await entries(on: db), existing: existing, limit: limit)
        } catch let problem as SkillRules.Problem {
            throw Abort(.badRequest, reason: problem.message)
        }
    }

    /// The skills most held by people whose job title is like `jobTitle`
    /// (trigram similarity, so "iOS Dev" finds "iOS Developer"), catalogue
    /// entries only, LinkedIn's "suggested based on your profile".
    static func suggested(forJobTitle jobTitle: String, on db: any SQLDatabase) async throws -> [String] {
        let title = jobTitle.trimmingCharacters(in: .whitespaces)
        guard title.count >= 2 else { return [] }
        struct R: Decodable { let name_en: String }
        return try await db.raw("""
            SELECT c.name_en
            FROM users u
            JOIN user_skills us ON us.user_id = u.id
            JOIN skill_catalog c ON LOWER(c.name_en) = LOWER(us.skill)
            WHERE u.job_title IS NOT NULL AND u.deleted_at IS NULL
              AND (u.job_title ILIKE '%' || \(bind: title) || '%' OR similarity(u.job_title, \(bind: title)) > 0.3)
            GROUP BY c.name_en
            ORDER BY COUNT(*) DESC, c.name_en
            LIMIT \(bind: suggestedCount)
            """).all(decoding: R.self).map(\.name_en)
    }

    /// Stores a suggestion for review; it is not added to the profile.
    static func suggest(_ text: String, userID: String, on db: any SQLDatabase) async throws {
        try await db.raw("""
            INSERT INTO interest_suggestions (user_id, text, kind) VALUES (\(uuid: userID), \(bind: text), 'skill')
            ON CONFLICT (user_id, text) DO NOTHING
            """).run()
    }
}

/// The checks behind every saved skill list, kept free of the database so
/// they can be unit-tested.
enum SkillRules {
    enum Problem: Error, Equatable {
        case notInCatalog(String), tooMany(Int)

        var message: String {
            switch self {
            case .notInCatalog(let s): return "\"\(s)\" isn't in the skill list. Pick from the list or suggest it"
            case .tooMany(let n):      return "Pick at most \(n) skills"
            }
        }
    }

    /// The entry with this English name or alias (case-insensitive).
    static func entry(named text: String, in entries: [SkillStore.Entry]) -> SkillStore.Entry? {
        let t = text.trimmingCharacters(in: .whitespaces).lowercased()
        return entries.first { $0.name_en.lowercased() == t || $0.aliases.contains(t) }
    }

    /// Catalogue spelling, duplicates dropped ("reactjs" and "React" are one),
    /// at most `limit`.
    static func normalize(_ items: [String], entries: [SkillStore.Entry], existing: Set<String>,
                          limit: Int) throws -> [String] {
        var picks: [String] = []
        var seen = Set<String>()
        for raw in items {
            let item = raw.trimmingCharacters(in: .whitespaces)
            guard !item.isEmpty else { continue }
            let name: String
            if let e = entry(named: item, in: entries) {
                name = e.name_en
            } else if existing.contains(item) {
                name = item
            } else {
                throw Problem.notInCatalog(item)
            }
            if seen.insert(name.lowercased()).inserted { picks.append(name) }
        }
        guard picks.count <= limit else { throw Problem.tooMany(limit) }
        return picks
    }
}

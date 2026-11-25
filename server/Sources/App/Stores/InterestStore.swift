import Vapor
import SQLKit

/// The curated interest catalogue (migration 080): what the picker offers,
/// what a profile may hold, and the aliases AI search reads prompts against.
/// A pick is stored by its English name ("Football"), or as
/// "Category · specific" ("Gaming · Roblox") for categories that take one.
enum InterestStore {
    /// Bumble shows 5 badges and Meetup takes 15 topics; 10 leaves room for
    /// hobbies and lifestyle without turning a profile into a list.
    static let maxPicks = 10
    static let maxTextLength = 40
    static let separator = " · "

    // MARK: - Catalog
    struct Entry: Content {
        var id: String
        var name_en: String
        var name_vi: String
        var category: String
        @NullCoded var parent_id: String?
        var aliases: [String]
        var allows_specific: Bool
        var pick_count: Int
    }
    struct Category: Content {
        var key: String; var name_en: String; var name_vi: String; var section: String
    }

    /// Every entry with how many profiles picked it ("Gaming · Roblox" counts
    /// for Gaming), so the picker can put the popular ones first.
    static func entries(on db: any SQLDatabase) async throws -> [Entry] {
        try await db.raw("""
            SELECT c.id::text AS id, c.name_en, c.name_vi, c.category, c.parent_id::text AS parent_id,
                   c.aliases, c.allows_specific,
                   (SELECT COUNT(*)::int FROM user_interests ui
                     WHERE LOWER(split_part(ui.interest, ' · ', 1)) = LOWER(c.name_en)) AS pick_count
            FROM interest_catalog c
            """).all(decoding: Entry.self)
    }

    static func categories(on db: any SQLDatabase) async throws -> [Category] {
        try await db.raw("SELECT key, name_en, name_vi, section FROM interest_categories")
            .all(decoding: Category.self)
    }

    // MARK: - Picks
    static func current(of userID: String, on db: any SQLDatabase) async throws -> [String] {
        struct R: Decodable { let interest: String }
        return try await db.raw("SELECT interest FROM user_interests WHERE user_id = \(uuid: userID)")
            .all(decoding: R.self).map(\.interest)
    }

    /// Checks a list about to be saved and returns it in catalogue spelling.
    /// Picks the person already had stay valid, so a profile from before the
    /// catalogue can still be edited.
    static func cleanPicks(_ items: [String], userID: String?, on db: any SQLDatabase) async throws -> [String] {
        let entries = try await entries(on: db)
        var existing = Set<String>()
        if let userID { existing = Set(try await current(of: userID, on: db)) }
        do {
            let checked = try InterestRules.normalize(items, entries: entries, existing: existing)
            var picks = checked.picks
            for (index, base, specific) in checked.specifics {
                guard let name = try await knownName(specific, entries: entries, on: db) else {
                    throw InlineError(.badRequest, "We couldn't find \"\(specific)\". Pick it from the suggestions")
                }
                picks[index] = base + separator + name
            }
            return picks
        } catch let problem as InterestRules.Problem {
            throw InlineError(.badRequest, problem.message)
        }
    }

    // MARK: - Specific interests and suggestions
    /// A specific item's canonical name when it names something already known:
    /// a catalogue entry or one of the interest entities.
    static func knownName(_ text: String, entries: [Entry], on db: any SQLDatabase) async throws -> String? {
        if let e = InterestRules.entry(named: text, in: entries) { return e.name_en }
        return try await SearchStore.exactMatch(text, category: nil, on: db)?.canonical_name
    }

    /// Resolves what someone typed for "Category · specific", looking it up
    /// (vector, then Wikipedia) when it isn't known yet. Nil when it names
    /// nothing real.
    static func resolveSpecific(_ text: String, entries: [Entry], cfg: OllamaService.Config, client: HTTPClient,
                                on db: any SQLDatabase, logger: Logger) async throws -> String? {
        if let name = try await knownName(text, entries: entries, on: db) { return name }
        let hit = await EntityLookupService.lookupEntity(text, category: nil, isName: true, cfg: cfg, client: client, on: db, logger: logger)
        return hit.confidence == "none" ? nil : hit.canonicalName
    }

    /// Stores a suggestion for review; it is not added to the profile.
    static func suggest(_ text: String, userID: String, on db: any SQLDatabase) async throws {
        try await db.raw("""
            INSERT INTO interest_suggestions (user_id, text) VALUES (\(uuid: userID), \(bind: text))
            ON CONFLICT (user_id, text) DO NOTHING
            """).run()
    }
}

// MARK: - Interest rules
/// The checks behind every saved interest list, kept free of the database so
/// they can be unit-tested.
enum InterestRules {
    enum Problem: Error, Equatable {
        case notInCatalog(String), noSpecific(String), badText, blocked, tooMany

        var message: String {
            switch self {
            case .notInCatalog(let s): return "\"\(s)\" isn't in the interest list. Pick from the list or suggest it"
            case .noSpecific(let s):   return "\"\(s)\" doesn't take a specific item"
            case .badText:             return "Use 2–\(InterestStore.maxTextLength) characters, including a letter"
            case .blocked:             return "That isn't allowed as an interest"
            case .tooMany:             return "Pick at most \(InterestStore.maxPicks) interests"
            }
        }
    }

    /// Lowercased, accents folded, "đ" → "d".
    static func fold(_ s: String) -> String {
        s.lowercased()
            .replacingOccurrences(of: "đ", with: "d")
            .folding(options: [.diacriticInsensitive], locale: Locale(identifier: "en"))
    }

    /// The entry with this English name or alias (case-insensitive).
    static func entry(named text: String, in entries: [InterestStore.Entry]) -> InterestStore.Entry? {
        let t = text.trimmingCharacters(in: .whitespaces).lowercased()
        return entries.first { $0.name_en.lowercased() == t || $0.aliases.contains(t) }
    }

    /// Typed text (a specific item or a suggestion): 2–40 characters with a
    /// letter, nothing on the blocklist. Returns it with spaces tidied.
    static func cleanText(_ raw: String?) throws -> String {
        let t = (raw ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard (2...InterestStore.maxTextLength).contains(t.count), t.contains(where: \.isLetter) else {
            throw Problem.badText
        }
        guard !isBlocked(t) else { throw Problem.blocked }
        return t
    }

    /// Whole words only, so "cockatiel" or "Sussex" aren't caught. Vietnamese
    /// is matched with its accents where folding would collide ("các" is a
    /// plural, "lợn" a pig). The lists live in `ModerationRules`, shared with
    /// the checks on posts, comments and messages.
    static func isBlocked(_ text: String) -> Bool { ModerationRules.isListedForInterests(text) }

    /// Catalogue spelling, duplicates dropped, at most `maxPicks`. Each
    /// "Category · specific" pick also comes back with its index, for the
    /// caller to check against known entities (that needs the database).
    static func normalize(_ items: [String], entries: [InterestStore.Entry], existing: Set<String>) throws
        -> (picks: [String], specifics: [(index: Int, base: String, specific: String)]) {
        var picks: [String] = []
        var specifics: [(index: Int, base: String, specific: String)] = []
        var seen = Set<String>()
        for raw in items {
            let item = raw.trimmingCharacters(in: .whitespaces)
            guard !item.isEmpty, seen.insert(item.lowercased()).inserted else { continue }
            if existing.contains(item) { picks.append(item); continue }
            let parts = item.components(separatedBy: InterestStore.separator)
            guard let base = entry(named: parts[0], in: entries) else { throw Problem.notInCatalog(parts[0]) }
            guard parts.count > 1 else { picks.append(base.name_en); continue }
            guard base.allows_specific else { throw Problem.noSpecific(base.name_en) }
            let specific = try cleanText(parts.dropFirst().joined(separator: InterestStore.separator))
            specifics.append((picks.count, base.name_en, specific))
            picks.append(base.name_en + InterestStore.separator + specific)
        }
        guard picks.count <= InterestStore.maxPicks else { throw Problem.tooMany }
        return (picks, specifics)
    }
}

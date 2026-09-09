import Vapor
import SQLKit

/// Port of `backend/src/services/entityLookupService.js` — the 3-tier
/// text → canonical `interest_entities` lookup:
///   Tier 1 exact (SQL), Tier 2 confident vector (≥0.8, auto-saves the alias),
///   Tier 3 Wikipedia (proper nouns → fetch + LLM-parse → INSERT so Tier 1
///   catches it next time).
enum EntityLookupService {
    struct Result {
        var entityID: String?
        var canonicalName: String?
        var category: String?
        var confidence: String   // exact | vector | wikipedia | none
        var genreTags: [String]  // only on wikipedia
    }

    /// Append `keyword` to an entity's aliases (idempotent). Returns canonical name or nil.
    @discardableResult
    static func saveAlias(_ keyword: String, entityID: String, on db: any SQLDatabase) async throws -> String? {
        let alias = keyword.trimmingCharacters(in: .whitespaces)
        guard !alias.isEmpty else { return nil }
        struct E: Decodable { let id: String; let canonical_name: String; let aliases: [String]? }
        guard let e = try await db.raw("SELECT id::text AS id, canonical_name, aliases FROM interest_entities WHERE id = \(uuid: entityID)")
            .first(decoding: E.self) else { return nil }
        if !(e.aliases ?? []).map({ $0.lowercased() }).contains(alias.lowercased()) {
            try await db.raw("UPDATE interest_entities SET aliases = array_append(aliases, \(bind: alias)) WHERE id = \(uuid: entityID)").run()
        }
        return e.canonical_name
    }

    static func lookupEntity(_ text: String, category: String?, cfg: OllamaService.Config,
                             client: HTTPClient, on db: any SQLDatabase, logger: Logger) async -> Result {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return Result(confidence: "none", genreTags: []) }

        // Tier 1 — exact
        if let hit = try? await SearchStore.exactMatch(trimmed, category: category, on: db) {
            return Result(entityID: hit.id, canonicalName: hit.canonical_name, category: hit.category,
                          confidence: "exact", genreTags: [])
        }

        // Tier 2 — confident vector (auto-save alias, fire-and-forget)
        if let vec = await OllamaService.embedText(cfg, trimmed, logger: logger),
           let top = (try? await SearchStore.findEntityCandidates(vec, category: category, limit: 1, on: db))?.first,
           top.similarity >= SearchStore.highConfidenceThreshold {
            Task { try? await saveAlias(trimmed, entityID: top.entity_id, on: db) }
            return Result(entityID: top.entity_id, canonicalName: top.canonical_name, category: top.category,
                          confidence: "vector", genreTags: [])
        }

        // Tier 3 — Wikipedia (proper nouns)
        if WikipediaService.isProperNoun(trimmed) {
            if let wiki = await WikipediaService.searchWikipedia(trimmed, client: client, logger: logger),
               let parsed = await WikipediaService.parseWikiData(wiki, cfg: cfg, logger: logger) {
                struct R: Decodable { let id: String; let canonical_name: String; let category: String? }
                if let row = try? await db.raw("""
                    INSERT INTO interest_entities (canonical_name, aliases, category)
                    VALUES (\(bind: parsed.canonicalName), \(bind: parsed.aliases)::text[], \(bind: parsed.category))
                    ON CONFLICT (canonical_name, category) DO UPDATE
                      SET aliases = (SELECT array_agg(DISTINCT a ORDER BY a)
                                     FROM UNNEST(interest_entities.aliases || EXCLUDED.aliases) a)
                    RETURNING id::text AS id, canonical_name, category
                    """).first(decoding: R.self) {
                    logger.info("Tier 3 Wikipedia match — entity saved: \(row.canonical_name)")
                    return Result(entityID: row.id, canonicalName: row.canonical_name, category: row.category,
                                  confidence: "wikipedia", genreTags: parsed.genreTags)
                }
            }
        }

        return Result(confidence: "none", genreTags: [])
    }
}

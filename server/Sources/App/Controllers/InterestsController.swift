import Vapor
import SQLKit

/// `/api/interests`, the curated catalogue the interest picker shows
/// (`InterestStore`), the check behind a "Category · specific" pick, and
/// suggestions for entries the catalogue lacks.
struct InterestsController {
    static func register(routes: any RoutesBuilder) {
        // The catalogue and the specific-item check are open: an email sign-up
        // picks interests before its account exists.
        let i = routes.grouped("interests")
        i.get("catalog", use: catalog)
        // These reach Ollama and Wikipedia, and suggestions are reviewed by hand.
        i.grouped(RateLimitMiddleware.clarify()).post("specific", use: specific)
        i.grouped(AuthMiddleware()).grouped(RateLimitMiddleware.clarify()).post("suggestions", use: suggest)
    }

    // MARK: - Catalog
    struct CatalogCategory: Content {
        var key: String; var name_en: String; var name_vi: String; var section: String
        var entries: [InterestStore.Entry]
    }
    struct CatalogResponse: Content { var categories: [CatalogCategory]; var max_picks: Int }

    /// Most-picked categories and entries first; the lifestyle section
    /// (smoking, drinking…) always last.
    static func catalog(_ req: Request) async throws -> CatalogResponse {
        let db = req.db.sql()
        let entries = try await InterestStore.entries(on: db)
        let byCategory = Dictionary(grouping: entries, by: \.category)
        let categories = try await InterestStore.categories(on: db).map { c in
            CatalogCategory(key: c.key, name_en: c.name_en, name_vi: c.name_vi, section: c.section,
                            entries: (byCategory[c.key] ?? []).sorted(by: morePicked))
        }
        return CatalogResponse(categories: sortCategories(categories), max_picks: InterestStore.maxPicks)
    }

    static func morePicked(_ a: InterestStore.Entry, _ b: InterestStore.Entry) -> Bool {
        a.pick_count != b.pick_count ? a.pick_count > b.pick_count : a.name_en < b.name_en
    }

    static func sortCategories(_ categories: [CatalogCategory]) -> [CatalogCategory] {
        func picks(_ c: CatalogCategory) -> Int { c.entries.reduce(0) { $0 + $1.pick_count } }
        return categories.sorted {
            if ($0.section == "lifestyle") != ($1.section == "lifestyle") { return $1.section == "lifestyle" }
            return picks($0) != picks($1) ? picks($0) > picks($1) : $0.name_en < $1.name_en
        }
    }

    // MARK: - Specific interest
    struct SpecificBody: Content { var base: String?; var text: String? }
    struct SpecificResponse: Content { var interest: String; var name: String }

    /// "Gaming" + "roblox" → "Gaming · Roblox". Only things that exist pass: a
    /// catalogue entry, a known entity, or one found on Wikipedia.
    static func specific(_ req: Request) async throws -> SpecificResponse {
        let b = try req.content.decode(SpecificBody.self)
        let db = req.db.sql()
        let entries = try await InterestStore.entries(on: db)
        guard let base = InterestRules.entry(named: b.base ?? "", in: entries), base.allows_specific else {
            throw Abort(.badRequest, reason: "Pick a category that takes a specific item")
        }
        let text: String
        do { text = try InterestRules.cleanText(b.text) } catch let p as InterestRules.Problem {
            throw Abort(.badRequest, reason: p.message)
        }
        guard let name = try await InterestStore.resolveSpecific(
            text, entries: entries, cfg: req.ollama, client: req.application.http.client.shared, on: db, logger: req.logger)
        else { throw Abort(.notFound, reason: "We couldn't find \"\(text)\"") }
        return SpecificResponse(interest: base.name_en + InterestStore.separator + name, name: name)
    }

    // MARK: - Suggestions
    struct SuggestBody: Content { var text: String? }
    struct SuggestResponse: Content {
        var status: String
        /// Set when the catalogue already has it under another name.
        @NullCoded var existing: String?
    }

    static func suggest(_ req: Request) async throws -> SuggestResponse {
        let b = try req.content.decode(SuggestBody.self)
        let text: String
        do { text = try InterestRules.cleanText(b.text) } catch let p as InterestRules.Problem {
            throw Abort(.badRequest, reason: p.message)
        }
        let db = req.db.sql()
        if let e = InterestRules.entry(named: text, in: try await InterestStore.entries(on: db)) {
            return SuggestResponse(status: "exists", existing: e.name_en)
        }
        try await InterestStore.suggest(text, userID: req.userID, on: db)
        return SuggestResponse(status: "ok", existing: nil)
    }
}

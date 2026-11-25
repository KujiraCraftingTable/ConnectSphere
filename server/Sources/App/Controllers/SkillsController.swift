import Vapor
import SQLKit

/// `/api/skills`, the curated catalogue the Work skill picker shows
/// (`SkillStore`), with skills suggested from a job title, and suggestions for
/// skills the catalogue lacks.
struct SkillsController {
    static func register(routes: any RoutesBuilder) {
        // Open, like the interest catalogue: onboarding picks skills before an
        // email sign-up has an account.
        let s = routes.grouped("skills")
        s.get("catalog", use: catalog)
        s.grouped(AuthMiddleware()).grouped(RateLimitMiddleware.clarify()).post("suggestions", use: suggest)
    }

    // MARK: - Catalog
    struct CatalogCategory: Content {
        var key: String; var name_en: String; var name_vi: String
        var entries: [SkillStore.Entry]
    }
    struct CatalogResponse: Content {
        var categories: [CatalogCategory]
        /// Catalogue names, most held by people with a similar job title first.
        var suggested: [String]
        var max_picks: Int
        var max_job_picks: Int
    }

    /// `?job_title=` adds the "Suggested for you" names.
    static func catalog(_ req: Request) async throws -> CatalogResponse {
        let db = req.db.sql()
        let entries = try await SkillStore.entries(on: db)
        let byCategory = Dictionary(grouping: entries, by: \.category)
        let categories = try await SkillStore.categories(on: db).map { c in
            CatalogCategory(key: c.key, name_en: c.name_en, name_vi: c.name_vi,
                            entries: (byCategory[c.key] ?? []).sorted(by: morePicked))
        }
        let title = String((req.query[String.self, at: "job_title"] ?? "").prefix(100))
        return CatalogResponse(categories: sortCategories(categories),
                               suggested: try await SkillStore.suggested(forJobTitle: title, on: db),
                               max_picks: SkillStore.maxProfile, max_job_picks: SkillStore.maxJob)
    }

    static func morePicked(_ a: SkillStore.Entry, _ b: SkillStore.Entry) -> Bool {
        a.pick_count != b.pick_count ? a.pick_count > b.pick_count : a.name_en < b.name_en
    }

    static func sortCategories(_ categories: [CatalogCategory]) -> [CatalogCategory] {
        func picks(_ c: CatalogCategory) -> Int { c.entries.reduce(0) { $0 + $1.pick_count } }
        return categories.sorted { picks($0) != picks($1) ? picks($0) > picks($1) : $0.name_en < $1.name_en }
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
        if let e = SkillRules.entry(named: text, in: try await SkillStore.entries(on: db)) {
            return SuggestResponse(status: "exists", existing: e.name_en)
        }
        try await SkillStore.suggest(text, userID: req.userID, on: db)
        return SuggestResponse(status: "ok", existing: nil)
    }
}

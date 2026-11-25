import Vapor
import SQLKit

/// `/api/admin/interests`: the official account reviews the interests people
/// suggested from the picker (`interest_suggestions`, migration 080). Approving
/// adds one entry to `interest_catalog` and marks every matching suggestion
/// added; rejecting marks them rejected. Admin only.
struct AdminInterestsController {
    static func register(routes: any RoutesBuilder) {
        let a = routes.grouped("admin", "interests").grouped(AuthMiddleware()).grouped(AppRoleMiddleware(adminOnly: true))
        a.get("suggestions", use: list)
        a.post("suggestions", "approve", use: approve)
        a.post("suggestions", "reject", use: reject)
    }

    // MARK: - Listing
    /// One suggested text, however many people sent it (case and spaces ignored).
    struct Suggestion: Content {
        var text: String
        var count: Int
        var first_at: Date
        var last_at: Date
    }
    struct Category: Content { var key: String; var name_en: String; var name_vi: String }
    struct ListResponse: Content { var suggestions: [Suggestion]; var categories: [Category] }

    static func list(_ req: Request) async throws -> ListResponse {
        let db = req.db.sql()
        let suggestions = try await db.raw("""
            SELECT MIN(text) AS text, COUNT(*)::int AS count, MIN(created_at) AS first_at, MAX(created_at) AS last_at
            FROM interest_suggestions WHERE status = 'pending'
            GROUP BY LOWER(TRIM(text))
            ORDER BY COUNT(*) DESC, MIN(created_at)
            LIMIT 200
            """).all(decoding: Suggestion.self)
        let categories = try await db.raw("""
            SELECT key, name_en, name_vi FROM interest_categories ORDER BY section, name_en
            """).all(decoding: Category.self)
        return ListResponse(suggestions: suggestions, categories: categories)
    }

    // MARK: - Approve
    struct ApproveBody: Content {
        var text: String?; var name_en: String?; var name_vi: String?; var category: String?
        var allows_specific: Bool?
    }
    /// The checked approve input.
    struct Approval: Equatable {
        let text: String; let nameEN: String; let nameVI: String; let category: String; let allowsSpecific: Bool
    }

    static let maxName = 40

    /// Pure, so it's unit-tested: every field present, trimmed and short enough.
    static func validate(_ b: ApproveBody) throws -> Approval {
        func clean(_ s: String?, _ field: String) throws -> String {
            let t = (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { throw Abort(.badRequest, reason: "\(field) is required") }
            guard t.count <= maxName else { throw Abort(.badRequest, reason: "\(field) must be at most \(maxName) characters") }
            return t
        }
        return Approval(text: try clean(b.text, "text"), nameEN: try clean(b.name_en, "name_en"),
                        nameVI: try clean(b.name_vi, "name_vi"), category: try clean(b.category, "category"),
                        allowsSpecific: b.allows_specific ?? false)
    }

    struct Done: Content { var updated: Int }

    static func approve(_ req: Request) async throws -> Done {
        let a = try validate(try req.content.decode(ApproveBody.self))
        // `tx` returns nothing, so the count comes out through this box.
        final class Count: @unchecked Sendable { var value = 0 }
        let count = Count()
        try await req.db.tx { db in
            struct Exists: Decodable { let one: Int }
            guard try await db.raw("SELECT 1 AS one FROM interest_categories WHERE key = \(bind: a.category)")
                .first(decoding: Exists.self) != nil else {
                throw Abort(.badRequest, reason: "Unknown category")
            }
            // Already in the catalog under that English name: just close the suggestions.
            try await db.raw("""
                INSERT INTO interest_catalog (name_en, name_vi, category, allows_specific)
                VALUES (\(bind: a.nameEN), \(bind: a.nameVI), \(bind: a.category), \(bind: a.allowsSpecific))
                ON CONFLICT (LOWER(name_en)) DO NOTHING
                """).run()
            count.value = try await closeSuggestions(a.text, status: "added", on: db)
        }
        return Done(updated: count.value)
    }

    // MARK: - Reject
    struct RejectBody: Content { var text: String? }

    static func reject(_ req: Request) async throws -> Done {
        let text = (try req.content.decode(RejectBody.self).text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw Abort(.badRequest, reason: "text is required") }
        return Done(updated: try await closeSuggestions(text, status: "rejected", on: req.db.sql()))
    }

    /// Marks every pending suggestion with this text (case and spaces ignored).
    private static func closeSuggestions(_ text: String, status: String, on db: any SQLDatabase) async throws -> Int {
        struct R: Decodable { let id: String }
        return try await db.raw("""
            UPDATE interest_suggestions SET status = \(bind: status)
            WHERE status = 'pending' AND LOWER(TRIM(text)) = LOWER(\(bind: text))
            RETURNING id::text AS id
            """).all(decoding: R.self).count
    }
}

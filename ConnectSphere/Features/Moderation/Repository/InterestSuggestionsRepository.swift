import Foundation

// MARK: - Models
/// An interest people suggested from the picker, however many sent it.
struct InterestSuggestion: Decodable, Identifiable, Hashable {
    let text: String
    let count: Int
    let firstAt: Date
    let lastAt: Date

    var id: String { text.lowercased() }

    enum CodingKeys: String, CodingKey {
        case text, count
        case firstAt = "first_at"
        case lastAt = "last_at"
    }
}

/// A catalog category an approved interest can go into.
struct InterestCategoryOption: Decodable, Identifiable, Hashable {
    let key: String
    let nameEn: String
    let nameVi: String

    var id: String { key }

    enum CodingKeys: String, CodingKey {
        case key
        case nameEn = "name_en"
        case nameVi = "name_vi"
    }
}

// MARK: - Repository
/// The official account's review of suggested interests
/// (`/admin/interests/suggestions`). HTTP + decoding only.
struct InterestSuggestionsRepository {
    private let client = NetworkClient.shared
    private struct Done: Decodable { let updated: Int }
    private struct ListResponse: Decodable {
        let suggestions: [InterestSuggestion]
        let categories: [InterestCategoryOption]
    }

    func list(token: String) async throws -> (suggestions: [InterestSuggestion], categories: [InterestCategoryOption]) {
        let r = try await client.fetch(ListResponse.self, path: "/admin/interests/suggestions", token: token)
        return (r.suggestions, r.categories)
    }

    func approve(text: String, nameEn: String, nameVi: String, category: String, allowsSpecific: Bool,
                 token: String) async throws {
        let body: [String: Any] = ["text": text, "name_en": nameEn, "name_vi": nameVi,
                                   "category": category, "allows_specific": allowsSpecific]
        _ = try await client.fetch(Done.self, path: "/admin/interests/suggestions/approve", method: "POST",
                                   token: token, bodyData: try JSONSerialization.data(withJSONObject: body))
    }

    func reject(text: String, token: String) async throws {
        _ = try await client.fetch(Done.self, path: "/admin/interests/suggestions/reject", method: "POST",
                                   token: token, bodyData: try JSONSerialization.data(withJSONObject: ["text": text]))
    }
}

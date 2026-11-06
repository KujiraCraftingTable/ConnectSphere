import Foundation

/// One entry of the curated interest catalogue (server migration 080).
struct InterestEntry: Decodable, Identifiable, Hashable {
    let nameEn: String
    let nameVi: String
    let aliases: [String]
    /// Takes a "Category · specific" item (Gaming · Roblox).
    let allowsSpecific: Bool
    let pickCount: Int

    var id: String { nameEn }

    enum CodingKeys: String, CodingKey {
        case nameEn = "name_en", nameVi = "name_vi", aliases
        case allowsSpecific = "allows_specific", pickCount = "pick_count"
    }
}

struct InterestCategory: Decodable, Identifiable {
    let key: String
    let nameEn: String
    let nameVi: String
    /// "main", or "lifestyle" (smoking, drinking…), which the server sorts last.
    let section: String
    let entries: [InterestEntry]

    var id: String { key }

    enum CodingKeys: String, CodingKey {
        case key, nameEn = "name_en", nameVi = "name_vi", section, entries
    }
}

struct InterestCatalog: Decodable {
    let categories: [InterestCategory]
    let maxPicks: Int

    enum CodingKeys: String, CodingKey { case categories, maxPicks = "max_picks" }
}

/// `/api/interests`, HTTP + decoding only.
struct InterestRepository {
    private let client = NetworkClient.shared

    /// Suggestions are stored against an account; an email sign-up has none yet.
    var canSuggest: Bool { KeychainHelper.load(forKey: KeychainHelper.tokenKey) != nil }

    func catalog() async throws -> InterestCatalog {
        try await client.fetch(InterestCatalog.self, from: .interestCatalog)
    }

    /// The pick to store ("Gaming · Roblox"); throws when it names nothing real.
    func checkSpecific(base: String, text: String) async throws -> String {
        struct R: Decodable { let interest: String }
        return try await client.fetch(R.self, from: .interestSpecific(base: base, text: text)).interest
    }

    /// Nil when it was stored for review; otherwise the catalogue entry that
    /// already covers it.
    func suggest(_ text: String) async throws -> String? {
        guard let token = KeychainHelper.load(forKey: KeychainHelper.tokenKey) else {
            throw APIError.serverError(statusCode: 401, message: "Not authenticated")
        }
        struct Body: Encodable { let text: String }
        struct R: Decodable { let existing: String? }
        return try await client.fetch(R.self, path: "/interests/suggestions", method: "POST", token: token,
                                      bodyData: try JSONEncoder().encode(Body(text: text))).existing
    }
}

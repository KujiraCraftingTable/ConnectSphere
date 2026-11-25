import Foundation

// MARK: - Catalog models
/// One skill of the curated Work catalogue (server migration 084).
struct SkillEntry: Decodable, Identifiable, Hashable {
    let nameEn: String
    let nameVi: String
    let aliases: [String]
    let pickCount: Int

    var id: String { nameEn }

    enum CodingKeys: String, CodingKey {
        case nameEn = "name_en", nameVi = "name_vi", aliases, pickCount = "pick_count"
    }
}

struct SkillCategory: Decodable, Identifiable {
    let key: String
    let nameEn: String
    let nameVi: String
    let entries: [SkillEntry]

    var id: String { key }

    enum CodingKeys: String, CodingKey { case key, nameEn = "name_en", nameVi = "name_vi", entries }
}

struct SkillCatalog: Decodable {
    let categories: [SkillCategory]
    /// Most held by people with a similar job title first.
    let suggested: [String]
    let maxPicks: Int
    let maxJobPicks: Int

    enum CodingKeys: String, CodingKey {
        case categories, suggested, maxPicks = "max_picks", maxJobPicks = "max_job_picks"
    }
}

// MARK: - Repository
/// `/api/skills`, HTTP + decoding only.
struct SkillRepository {
    private let client = NetworkClient.shared

    /// Suggestions are stored against an account; an email sign-up has none yet.
    var canSuggest: Bool { KeychainHelper.load(forKey: KeychainHelper.tokenKey) != nil }

    func catalog(jobTitle: String?) async throws -> SkillCatalog {
        try await client.fetch(SkillCatalog.self, from: .skillCatalog(jobTitle: jobTitle))
    }

    /// Nil when it was stored for review; otherwise the catalogue skill that
    /// already covers it.
    func suggest(_ text: String) async throws -> String? {
        guard let token = KeychainHelper.load(forKey: KeychainHelper.tokenKey) else {
            throw APIError.serverError(statusCode: 401, message: "Not authenticated")
        }
        struct Body: Encodable { let text: String }
        struct R: Decodable { let existing: String? }
        return try await client.fetch(R.self, path: "/skills/suggestions", method: "POST", token: token,
                                      bodyData: try JSONEncoder().encode(Body(text: text))).existing
    }
}

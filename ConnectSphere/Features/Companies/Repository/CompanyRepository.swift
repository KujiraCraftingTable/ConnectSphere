import Foundation

/// Company pages API (`/companies`). HTTP + decoding only.
struct CompanyRepository {
    private let client = NetworkClient.shared

    /// What the create / edit form sends; blank fields clear on the server.
    struct Form: Encodable {
        var name: String
        var logo_url: String?
        var cover_url: String?
        var about: String
        var industry: String
        var size: String
        var website: String
        var headquarters: String
        var founded_year: Int?
    }

    func search(_ query: String, token: String) async throws -> [Company] {
        try await client.fetch(DataListResponse<Company>.self, path: "/companies", token: token,
                               queryItems: [.init(name: "q", value: query), .init(name: "limit", value: "30")]).data
    }

    func mine(token: String) async throws -> [Company] {
        try await client.fetch(DataListResponse<Company>.self, path: "/companies/mine", token: token).data
    }

    func company(id: String, token: String) async throws -> Company {
        try await client.fetch(DataResponse<Company>.self, path: "/companies/\(id)", token: token).data
    }

    func create(_ form: Form, token: String) async throws -> Company {
        try await client.fetch(DataResponse<Company>.self, path: "/companies", method: "POST", token: token,
                               bodyData: try JSONEncoder().encode(form)).data
    }

    func update(id: String, _ form: Form, token: String) async throws -> Company {
        try await client.fetch(DataResponse<Company>.self, path: "/companies/\(id)", method: "PATCH", token: token,
                               bodyData: try JSONEncoder().encode(form)).data
    }

    func setFollowing(_ follow: Bool, id: String, token: String) async throws -> Company {
        try await client.fetch(DataResponse<Company>.self, path: "/companies/\(id)/follow",
                               method: follow ? "POST" : "DELETE", token: token).data
    }
}

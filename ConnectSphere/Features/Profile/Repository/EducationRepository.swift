import Foundation

/// Schools on a Hobby profile (`/users/:id/educations`). HTTP + decoding only.
struct EducationRepository {
    private let client = NetworkClient.shared

    struct Form: Encodable {
        var school_name: String
        var school_type: String
        var major: String?
        var start_year: Int?
        var end_year: Int?
    }

    func list(of userId: String, token: String) async throws -> [Education] {
        try await client.fetch(DataListResponse<Education>.self, path: "/users/\(userId)/educations", token: token).data
    }

    func add(_ form: Form, token: String) async throws -> [Education] {
        try await client.fetch(DataListResponse<Education>.self, path: "/users/me/educations", method: "POST",
                               token: token, bodyData: NetworkClient.encode(form)).data
    }

    func update(id: String, _ form: Form, token: String) async throws -> [Education] {
        try await client.fetch(DataListResponse<Education>.self, path: "/users/me/educations/\(id)", method: "PATCH",
                               token: token, bodyData: NetworkClient.encode(form)).data
    }

    func remove(id: String, token: String) async throws -> [Education] {
        try await client.fetch(DataListResponse<Education>.self, path: "/users/me/educations/\(id)", method: "DELETE",
                               token: token).data
    }
}

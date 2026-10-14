import Foundation

/// Work history and a company's people. HTTP + decoding only.
struct WorkProfileRepository {
    private let client = NetworkClient.shared

    struct ExperienceForm: Encodable {
        var company_id: String?
        var company_name: String
        var title: String
        var employment_type: String
        var location: String
        var location_type: String?
        var start_month: String
        var end_month: String?
        var description: String
    }

    func experiences(of userId: String, token: String) async throws -> [WorkExperience] {
        try await client.fetch(DataListResponse<WorkExperience>.self, path: "/users/\(userId)/experiences", token: token).data
    }

    /// Each change answers with the whole updated list.
    func addExperience(_ form: ExperienceForm, token: String) async throws -> [WorkExperience] {
        try await client.fetch(DataListResponse<WorkExperience>.self, path: "/users/me/experiences", method: "POST",
                               token: token, bodyData: try JSONEncoder().encode(form)).data
    }

    func updateExperience(id: String, _ form: ExperienceForm, token: String) async throws -> [WorkExperience] {
        try await client.fetch(DataListResponse<WorkExperience>.self, path: "/users/me/experiences/\(id)", method: "PATCH",
                               token: token, bodyData: try JSONEncoder().encode(form)).data
    }

    func removeExperience(id: String, token: String) async throws -> [WorkExperience] {
        try await client.fetch(DataListResponse<WorkExperience>.self, path: "/users/me/experiences/\(id)",
                               method: "DELETE", token: token).data
    }

    func skills(of userId: String, token: String) async throws -> ProfileSkills {
        try await client.fetch(ProfileSkills.self, path: "/users/\(userId)/skills", token: token)
    }

    /// Endorses (or takes back) one of someone's skills; answers with the list.
    func setEndorsed(_ endorsed: Bool, skillId: Int, of userId: String, token: String) async throws -> ProfileSkills {
        try await client.fetch(ProfileSkills.self, path: "/users/\(userId)/skills/\(skillId)/endorse",
                               method: endorsed ? "POST" : "DELETE", token: token)
    }

    struct CompanyPerson: Identifiable, Decodable, Hashable {
        let id: String
        let displayName: String
        let avatarUrl: String?
        let avatarColor: String?
        let title: String
        let since: String
        enum CodingKeys: String, CodingKey {
            case id, title, since
            case displayName = "display_name"
            case avatarUrl = "avatar_url"
            case avatarColor = "avatar_color"
        }
    }

    func people(at companyId: String, token: String) async throws -> [CompanyPerson] {
        try await client.fetch(DataListResponse<CompanyPerson>.self, path: "/companies/\(companyId)/people", token: token).data
    }
}

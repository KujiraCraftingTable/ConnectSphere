import Foundation

/// A "Become HR" request, as the admin reviews it.
struct HRRequestItem: Decodable, Identifiable, Hashable {
    struct Person: Decodable, Hashable {
        let id: String
        let username: String
        let displayName: String
        let avatarUrl: String?
        let avatarColor: String?
        enum CodingKeys: String, CodingKey {
            case id, username
            case displayName = "display_name"
            case avatarUrl = "avatar_url"
            case avatarColor = "avatar_color"
        }
    }

    let id: String
    /// pending | approved | rejected | revoked
    let status: String
    let companyName: String
    let taxCode: String
    let website: String
    let workEmail: String
    let licencePath: String
    let reviewNote: String?
    let checklist: [String: Bool]?
    let createdAt: Date
    let person: Person
    /// "@username" already HR for this tax code: approving is refused.
    let conflictWith: String?

    enum CodingKeys: String, CodingKey {
        case id, status, website, checklist, person
        case companyName = "company_name"
        case taxCode = "tax_code"
        case workEmail = "work_email"
        case licencePath = "licence_path"
        case reviewNote = "review_note"
        case createdAt = "created_at"
        case conflictWith = "conflict_with"
    }
}

/// A new HR's job waiting for review before it goes live.
struct PendingJobItem: Decodable, Identifiable, Hashable {
    let postId: String
    let title: String
    let company: String?
    let location: String?
    let salaryRange: String?
    let careersUrl: String?
    let description: String?
    let createdAt: Date
    let person: HRRequestItem.Person

    var id: String { postId }

    enum CodingKeys: String, CodingKey {
        case title, company, location, description, person
        case postId = "post_id"
        case salaryRange = "salary_range"
        case careersUrl = "careers_url"
        case createdAt = "created_at"
    }
}

/// The official account's HR review (`/admin/hr`). HTTP + decoding only.
struct HRAdminRepository {
    private let client = NetworkClient.shared
    private struct Done: Decodable { let ok: Bool }

    func requests(status: String, token: String) async throws -> [HRRequestItem] {
        try await client.fetch(DataResponse<[HRRequestItem]>.self, path: "/admin/hr/requests", token: token,
                               queryItems: [.init(name: "status", value: status), .init(name: "limit", value: "50")]).data
    }

    /// `checklist` keys: email_verified, tax_code_registry, name_matches_licence, domain_matches_website.
    func decide(_ id: String, approve: Bool, checklist: [String: Bool], note: String?, token: String) async throws -> HRRequestItem {
        var body: [String: Any] = ["decision": approve ? "approve" : "reject", "checklist": checklist]
        if let note { body["note"] = note }
        return try await client.fetch(DataResponse<HRRequestItem>.self, path: "/admin/hr/requests/\(id)/decide",
                                      method: "POST", token: token,
                                      bodyData: try JSONSerialization.data(withJSONObject: body)).data
    }

    func revoke(userId: String, note: String, token: String) async throws {
        _ = try await client.fetch(Done.self, path: "/admin/hr/recruiters/\(userId)/revoke", method: "POST", token: token,
                                   bodyData: try JSONSerialization.data(withJSONObject: ["note": note]))
    }

    func pendingJobs(token: String) async throws -> [PendingJobItem] {
        try await client.fetch(DataResponse<[PendingJobItem]>.self, path: "/admin/hr/jobs/pending", token: token,
                               queryItems: [.init(name: "limit", value: "50")]).data
    }

    func decideJob(_ postId: String, approve: Bool, reason: String?, token: String) async throws {
        var body: [String: Any] = ["action": approve ? "approve" : "decline"]
        if let reason { body["reason"] = reason }
        _ = try await client.fetch(Done.self, path: "/admin/hr/jobs/\(postId)/decide", method: "POST", token: token,
                                   bodyData: try JSONSerialization.data(withJSONObject: body))
    }
}

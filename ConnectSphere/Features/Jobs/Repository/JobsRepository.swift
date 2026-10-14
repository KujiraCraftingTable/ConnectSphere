import Foundation

/// Jobs tab API (`/jobs`). HTTP + decoding only.
struct JobsRepository {
    private let client = NetworkClient.shared

    struct Filters: Equatable {
        var query = ""
        var location = ""
        var employmentType: EmploymentType?
        var workFormat: String?
        var level: String?
        var salaryMin: Int?

        var isEmpty: Bool { self == Filters() }

        var items: [URLQueryItem] {
            var items: [URLQueryItem] = []
            let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
            if !q.isEmpty { items.append(.init(name: "q", value: q)) }
            let l = location.trimmingCharacters(in: .whitespacesAndNewlines)
            if !l.isEmpty { items.append(.init(name: "location", value: l)) }
            if let employmentType { items.append(.init(name: "type", value: employmentType.rawValue)) }
            if let workFormat { items.append(.init(name: "format", value: workFormat)) }
            if let level { items.append(.init(name: "level", value: level)) }
            if let salaryMin { items.append(.init(name: "salary_min", value: String(salaryMin))) }
            return items
        }
    }

    func recommended(token: String) async throws -> [JobListing] {
        try await client.fetch(DataListResponse<JobListing>.self, path: "/jobs/recommended", token: token).data
    }

    func search(_ filters: Filters, token: String) async throws -> [JobListing] {
        try await client.fetch(DataListResponse<JobListing>.self, path: "/jobs", token: token, queryItems: filters.items).data
    }

    func saved(token: String) async throws -> [JobListing] {
        try await client.fetch(DataListResponse<JobListing>.self, path: "/jobs/saved", token: token).data
    }

    func job(id: String, token: String) async throws -> JobListing {
        try await client.fetch(DataResponse<JobListing>.self, path: "/jobs/\(id)", token: token).data
    }

    func companyJobs(companyId: String, token: String) async throws -> [JobListing] {
        try await client.fetch(DataListResponse<JobListing>.self, path: "/companies/\(companyId)/jobs", token: token).data
    }

    /// Saving is the job's existing "interested" toggle.
    func setSaved(_ saved: Bool, jobId: String, token: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["interested": saved])
        _ = try await client.fetch(OKResponse.self, path: "/jobs/\(jobId)/interest", method: "POST", token: token, bodyData: body)
    }
}

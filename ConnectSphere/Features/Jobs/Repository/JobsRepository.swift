import Foundation

/// Jobs tab API (`/jobs`). HTTP + decoding only.
struct JobsRepository {
    private let client = NetworkClient.shared

    struct Filters: Equatable {
        var query = ""
        /// Within this many km of your ward (5 km steps, like people search).
        var radiusKm: Int?
        var employmentType: EmploymentType?
        var workFormat: String?
        var level: String?
        var salaryMin: Int?

        var isEmpty: Bool { self == Filters() }

        var items: [URLQueryItem] {
            var items: [URLQueryItem] = []
            let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
            if !q.isEmpty { items.append(.init(name: "q", value: q)) }
            if let radiusKm { items.append(.init(name: "radius_km", value: String(radiusKm))) }
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

    /// Your own open jobs (an HR offering one on an "Open to work" post).
    func mine(token: String) async throws -> [JobListing] {
        try await client.fetch(DataListResponse<JobListing>.self, path: "/jobs/mine", token: token).data
    }

    // MARK: Saved CV (Work profile, server migration 131)

    private struct SavedCV: Decodable {
        let cvUrl: String?
        enum CodingKeys: String, CodingKey { case cvUrl = "cv_url" }
    }

    func myCV(token: String) async throws -> String? {
        try await client.fetch(DataResponse<SavedCV>.self, path: "/jobs/my-cv", token: token).data.cvUrl
    }

    /// Saves a CV uploaded with `uploadCV` on your profile.
    func saveMyCV(_ path: String, token: String) async throws {
        _ = try await client.fetch(DataResponse<SavedCV>.self, path: "/jobs/my-cv", method: "PUT", token: token,
                                   bodyData: try JSONSerialization.data(withJSONObject: ["cv_url": path]))
    }

    func removeMyCV(token: String) async throws {
        _ = try await client.fetch(DataResponse<SavedCV>.self, path: "/jobs/my-cv", method: "DELETE", token: token)
    }

    /// Someone's saved CV; only a verified HR gets one (404 otherwise).
    func profileCV(userId: String, token: String) async throws -> String? {
        try await client.fetch(DataResponse<SavedCV>.self, path: "/users/\(userId)/cv", token: token).data.cvUrl
    }

    func companyJobs(companyId: String, token: String) async throws -> [JobListing] {
        try await client.fetch(DataListResponse<JobListing>.self, path: "/companies/\(companyId)/jobs", token: token).data
    }

    // MARK: Easy Apply

    func apply(jobId: String, note: String?, cvUrl: String?, token: String) async throws -> JobApplication {
        var body: [String: Any] = [:]
        if let note { body["note"] = note }
        if let cvUrl { body["cv_url"] = cvUrl }
        return try await client.fetch(DataResponse<JobApplication>.self, path: "/jobs/\(jobId)/apply", method: "POST",
                                      token: token, bodyData: try JSONSerialization.data(withJSONObject: body)).data
    }

    func myApplications(token: String) async throws -> [JobApplication] {
        try await client.fetch(DataListResponse<JobApplication>.self, path: "/jobs/applications/mine", token: token).data
    }

    func applicants(jobId: String, token: String) async throws -> [JobApplication] {
        try await client.fetch(DataListResponse<JobApplication>.self, path: "/jobs/\(jobId)/applications", token: token).data
    }

    func setStatus(_ status: String, applicationId: String, token: String) async throws -> JobApplication {
        let body = try JSONSerialization.data(withJSONObject: ["status": status])
        return try await client.fetch(DataResponse<JobApplication>.self, path: "/jobs/applications/\(applicationId)",
                                      method: "PATCH", token: token, bodyData: body).data
    }

    /// A PDF CV; returns its private path (`/uploads/cv/…`).
    func uploadCV(_ data: Data, fileName: String, token: String) async throws -> String {
        let boundary = UUID().uuidString
        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n".utf8))
        body.append(Data("Content-Type: application/pdf\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        guard let url = URL(string: APIConfig.baseURL + "/jobs/cv") else { throw APIError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (responseData, response): (Data, URLResponse)
        do { (responseData, response) = try await URLSession.shared.data(for: request) }
        catch { throw APIError.networkError(error) }
        struct Uploaded: Decodable { let url: String }
        struct Failure: Decodable { let message: String }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(Failure.self, from: responseData))?.message ?? ""
            throw APIError.serverError(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0, message: message)
        }
        return try JSONDecoder().decode(Uploaded.self, from: responseData).url
    }

    /// Saving is the job's existing "interested" toggle.
    func setSaved(_ saved: Bool, jobId: String, token: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["interested": saved])
        _ = try await client.fetch(OKResponse.self, path: "/jobs/\(jobId)/interest", method: "POST", token: token, bodyData: body)
    }
}

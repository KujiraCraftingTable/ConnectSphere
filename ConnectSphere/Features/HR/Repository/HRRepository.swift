import Foundation

/// Your HR status, as `/hr/me` reports it.
struct HRStatus: Decodable, Equatable {
    /// none | pending | approved | rejected | revoked
    let status: String
    let companyName: String?
    let reviewNote: String?
    /// Approved only: jobs still to be reviewed before posting goes straight live.
    let trialLeft: Int?

    var isApproved: Bool { status == "approved" }

    enum CodingKeys: String, CodingKey {
        case status
        case companyName = "company_name"
        case reviewNote = "review_note"
        case trialLeft = "trial_left"
    }
}

/// Becoming a verified HR (`/hr`, server migration 126). HTTP + decoding only.
struct HRRepository {
    private let client = NetworkClient.shared

    struct Request: Encodable {
        var company_name: String
        var tax_code: String
        var website: String
        var email: String
        var code: String
        var licence_path: String
    }

    func status(token: String) async throws -> HRStatus {
        try await client.fetch(DataResponse<HRStatus>.self, path: "/hr/me", token: token).data
    }

    func sendCode(email: String, token: String) async throws {
        struct Sent: Decodable { let sent_to: String }
        _ = try await client.fetch(Sent.self, path: "/hr/email-code", method: "POST", token: token,
                                   bodyData: try JSONEncoder().encode(["email": email]))
    }

    func submit(_ request: Request, token: String) async throws -> HRStatus {
        try await client.fetch(DataResponse<HRStatus>.self, path: "/hr/requests", method: "POST", token: token,
                               bodyData: try JSONEncoder().encode(request)).data
    }

    /// The business registration PDF; returns its private path (`/uploads/hr/…`).
    func uploadLicence(_ data: Data, fileName: String, token: String) async throws -> String {
        try await uploadPDF(data, fileName: fileName, route: "/hr/licence", token: token)
    }

    /// The company's job description for a job; returns its `/uploads/jd/…` path.
    func uploadJD(_ data: Data, fileName: String, token: String) async throws -> String {
        try await uploadPDF(data, fileName: fileName, route: "/hr/jd", token: token)
    }

    private func uploadPDF(_ data: Data, fileName: String, route: String, token: String) async throws -> String {
        let boundary = UUID().uuidString
        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n".utf8))
        body.append(Data("Content-Type: application/pdf\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        guard let url = URL(string: APIConfig.baseURL + route) else { throw APIError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(NetworkClient.appMode, forHTTPHeaderField: "X-App-Mode")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (responseData, response): (Data, URLResponse)
        do { (responseData, response) = try await URLSession.shared.data(for: request) }
        catch { throw APIError.networkError(error) }
        struct Uploaded: Decodable { let path: String }
        struct Failure: Decodable { let message: String }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(Failure.self, from: responseData))?.message ?? ""
            throw APIError.serverError(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0, message: message)
        }
        return try JSONDecoder().decode(Uploaded.self, from: responseData).path
    }
}

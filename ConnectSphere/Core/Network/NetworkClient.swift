import Foundation

/// Unified HTTP client. Replaces both APIClient and CommunityAPIClient.
/// Pass a `token` for authenticated requests; omit for public endpoints.
final class NetworkClient {
    static let shared = NetworkClient()

    private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        session = URLSession(configuration: config)
    }

    // MARK: - Endpoint-based

    /// Tự gắn Bearer token từ Keychain nếu có — backend giờ yêu cầu JWT
    /// cho hầu hết endpoint và đọc danh tính từ token.
    func fetch<T: Decodable>(_ type: T.Type, from endpoint: Endpoint) async throws -> T {
        guard let url = endpoint.url else { throw APIError.invalidURL }
        var request = URLRequest(url: url, timeoutInterval: endpoint.timeoutInterval)
        request.httpMethod = endpoint.httpMethod
        if let token = KeychainHelper.load(forKey: KeychainHelper.tokenKey) {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body = endpoint.httpBody {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return try await perform(request, decoding: type)
    }

    // MARK: - Path-based (authenticated with Bearer token)

    func fetch<T: Decodable>(
        _ type: T.Type,
        path: String,
        method: String = "GET",
        token: String,
        queryItems: [URLQueryItem] = [],
        bodyData: Data? = nil
    ) async throws -> T {
        var components = URLComponents(string: APIConfig.baseURL + path)!
        if !queryItems.isEmpty { components.queryItems = queryItems }
        guard let url = components.url else { throw APIError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let bodyData {
            request.httpBody = bodyData
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return try await perform(request, decoding: type)
    }

    // MARK: - Encode helper (mirrors CommunityAPIClient.encode)

    static func encode<T: Encodable>(_ value: T) -> Data? {
        try? JSONEncoder().encode(value)
    }

    // MARK: - Private

    private func perform<T: Decodable>(_ request: URLRequest, decoding type: T.Type) async throws -> T {
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await session.data(for: request) }
        catch { throw APIError.networkError(error) }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let msg = (try? JSONDecoder().decode(ErrorResponse.self, from: data))?.message ?? "Unknown error"
            throw APIError.serverError(statusCode: http.statusCode, message: msg)
        }
        do { return try JSONDecoder.makeISO8601().decode(type, from: data) }
        catch { throw APIError.decodingFailed(error) }
    }
}

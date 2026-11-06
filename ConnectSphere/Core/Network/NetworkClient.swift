import Foundation

/// Unified HTTP client. Replaces both APIClient and CommunityAPIClient.
/// Pass a `token` for authenticated requests; omit for public endpoints.
final class NetworkClient {
    static let shared = NetworkClient()
    /// Path-based calls; endpoint-based ones carry their own (`Endpoint.timeoutInterval`).
    static let pathTimeout: TimeInterval = 30

    private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        // A whole request, retries included, never outlives AI search's 90 s.
        config.timeoutIntervalForResource = 120
        session = URLSession(configuration: config)
    }

    // MARK: - Endpoint-based

    /// Automatically attaches the Bearer token from the Keychain if present. The backend now
    /// requires a JWT for most endpoints and reads the caller's identity from it.
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

        var request = URLRequest(url: url, timeoutInterval: Self.pathTimeout)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let bodyData {
            request.httpBody = bodyData
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return try await perform(request, decoding: type)
    }

    // MARK: - Raw-body variant (for the SwiftData offline cache)

    /// Like `fetch(_:from:)` but also returns the exact response bytes, so the
    /// caller can write them through to `CacheStore` and re-decode an identical
    /// page offline later.
    func fetchRaw<T: Decodable>(_ type: T.Type, from endpoint: Endpoint) async throws -> (value: T, body: Data) {
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
        return try await performRaw(request, decoding: type)
    }

    func fetchRaw<T: Decodable>(
        _ type: T.Type,
        path: String,
        method: String = "GET",
        token: String,
        queryItems: [URLQueryItem] = [],
        bodyData: Data? = nil
    ) async throws -> (value: T, body: Data) {
        var components = URLComponents(string: APIConfig.baseURL + path)!
        if !queryItems.isEmpty { components.queryItems = queryItems }
        guard let url = components.url else { throw APIError.invalidURL }
        var request = URLRequest(url: url, timeoutInterval: Self.pathTimeout)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let bodyData {
            request.httpBody = bodyData
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return try await performRaw(request, decoding: type)
    }

    // MARK: - Encode helper (mirrors CommunityAPIClient.encode)

    static func encode<T: Encodable>(_ value: T) -> Data? {
        try? JSONEncoder().encode(value)
    }

    // MARK: - Private

    private func perform<T: Decodable>(_ request: URLRequest, decoding type: T.Type) async throws -> T {
        try await performRaw(request, decoding: type).value
    }

    private func performRaw<T: Decodable>(_ request: URLRequest, decoding type: T.Type) async throws -> (value: T, body: Data) {
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await session.data(for: request) }
        // A request cancelled with its screen isn't a network problem.
        catch let e as URLError where e.code == .cancelled { throw CancellationError() }
        catch { throw APIError.networkError(error) }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let msg = (try? JSONDecoder().decode(ErrorResponse.self, from: data))?.message ?? "Unknown error"
            throw APIError.serverError(statusCode: http.statusCode, message: msg)
        }
        do { return (try JSONDecoder.makeISO8601().decode(type, from: data), data) }
        catch { throw APIError.decodingFailed(error) }
    }
}

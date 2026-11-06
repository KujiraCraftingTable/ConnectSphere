import Foundation

/// Legacy authenticated client. Delegates to NetworkClient.
/// Kept for any callers not yet migrated to repositories.
final class CommunityAPIClient {
    static let shared = CommunityAPIClient()
    private init() {}

    func fetch<T: Decodable>(
        _ type: T.Type,
        path: String,
        method: String = "GET",
        token: String,
        queryItems: [URLQueryItem] = [],
        bodyData: Data? = nil
    ) async throws -> T {
        return try await NetworkClient.shared.fetch(
            type, path: path, method: method,
            token: token, queryItems: queryItems, bodyData: bodyData
        )
    }

    static func encode<T: Encodable>(_ value: T) -> Data? {
        NetworkClient.encode(value)
    }
}

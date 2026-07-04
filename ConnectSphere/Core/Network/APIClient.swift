import Foundation

/// Legacy unauthenticated client — delegates to NetworkClient.
/// Kept for any callers not yet migrated to repositories.
final class APIClient {
    static let shared = APIClient()
    private init() {}

    func fetch<T: Decodable>(_ type: T.Type, from endpoint: Endpoint) async throws -> T {
        return try await NetworkClient.shared.fetch(type, from: endpoint)
    }
}

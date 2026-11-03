import Foundation

/// Sends what the user looked at in a feed (`POST /feed/impressions`):
/// post ids with time on screen, and posts they opened. Nothing else.
struct ImpressionRepository {
    private let client = NetworkClient.shared

    struct Item: Encodable {
        let post_id: String
        let view_ms: Int
        let opened: Bool
    }

    func send(source: String, items: [Item]) async throws {
        guard let token = KeychainHelper.load(forKey: KeychainHelper.tokenKey) else {
            throw APIError.serverError(statusCode: 401, message: "Not authenticated")
        }
        struct Body: Encodable { let source: String; let items: [Item] }
        struct Resp: Decodable { let recorded: Int }
        _ = try await client.fetch(Resp.self, path: "/feed/impressions", method: "POST", token: token,
                                   bodyData: NetworkClient.encode(Body(source: source, items: items)))
    }
}

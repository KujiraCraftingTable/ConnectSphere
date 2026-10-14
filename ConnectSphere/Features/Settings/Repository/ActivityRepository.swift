import Foundation

/// Your activity log (`/users/me/activity`). HTTP + decoding only.
struct ActivityRepository {
    private let client = NetworkClient.shared

    enum Tab: String { case comments, reactions }

    func page(_ tab: Tab, offset: Int, token: String) async throws -> [ActivityItem] {
        let items = [URLQueryItem(name: "type", value: tab.rawValue), URLQueryItem(name: "limit", value: "30"),
                     URLQueryItem(name: "offset", value: String(offset))]
        return try await client.fetch(DataListResponse<ActivityItem>.self, path: "/users/me/activity", token: token,
                                      queryItems: items).data
    }
}

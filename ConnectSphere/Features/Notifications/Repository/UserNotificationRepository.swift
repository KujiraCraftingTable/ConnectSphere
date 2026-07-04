import Foundation

struct UserNotificationRepository {
    private let client = NetworkClient.shared

    func fetchAll(token: String) async throws -> UserNotificationListResponseDTO {
        return try await client.fetch(
            UserNotificationListResponseDTO.self,
            path: "/user-notifications",
            token: token
        )
    }

    /// Returns the first unresolved mode_mismatch notification for a specific post.
    func fetchMismatchFor(postId: String, token: String) async throws -> UserNotificationDTO? {
        let response = try await fetchAll(token: token)
        return response.data.first {
            $0.type == "mode_mismatch" &&
            $0.postId == postId &&
            $0.resolvedAt == nil
        }
    }

    func resolve(notificationId: String, action: String, token: String) async throws {
        struct Empty: Decodable {}
        let body = try? JSONEncoder().encode(["action": action])
        _ = try await client.fetch(
            Empty.self,
            path: "/user-notifications/\(notificationId)/resolve",
            method: "POST",
            token: token,
            bodyData: body
        )
    }

    func markRead(notificationId: String, token: String) async throws {
        struct Empty: Decodable {}
        _ = try await client.fetch(
            Empty.self,
            path: "/user-notifications/\(notificationId)/read",
            method: "POST",
            token: token
        )
    }

    func markAllRead(token: String) async throws {
        struct Empty: Decodable {}
        _ = try await client.fetch(
            Empty.self,
            path: "/user-notifications/read-all",
            method: "POST",
            token: token
        )
    }
}

import Foundation

/// `/api/posts/drafts` — the user's drafts and scheduled posts. HTTP + decoding only.
/// Saving and publishing go through the normal create routes (`publish`,
/// `replaces_draft`).
struct DraftRepository {
    private let client = NetworkClient.shared

    func list() async throws -> [Post] {
        try await client.fetch(DataResponse<[PostDTO]>.self, path: "/posts/drafts", token: try token()).data.map { $0.toPost() }
    }

    func delete(_ id: String) async throws {
        struct OK: Decodable { let status: String }
        _ = try await client.fetch(OK.self, path: "/posts/\(id)/draft", method: "DELETE", token: try token())
    }

    private func token() throws -> String {
        guard let token = KeychainHelper.load(forKey: KeychainHelper.tokenKey) else {
            throw APIError.serverError(statusCode: 401, message: "Not authenticated")
        }
        return token
    }
}

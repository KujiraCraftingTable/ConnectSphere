import Foundation

/// `/api/people/suggestions` (+ the connection request a card sends) — HTTP + decoding only.
struct SuggestionRepository {
    private let client = NetworkClient.shared

    func list(mode: AppMode) async throws -> [PeopleSuggestion] {
        try await client.fetch(DataResponse<[PeopleSuggestion]>.self, path: "/people/suggestions", token: try token(),
                               queryItems: [URLQueryItem(name: "mode", value: mode.rawValue)]).data
    }

    func dismiss(_ userId: String, mode: AppMode) async throws {
        struct OK: Decodable { let ok: Bool }
        _ = try await client.fetch(OK.self, path: "/people/suggestions/\(userId)/dismiss", method: "POST", token: try token(),
                                   queryItems: [URLQueryItem(name: "mode", value: mode.rawValue)])
    }

    func sendRequest(to userId: String, mode: AppMode) async throws {
        struct Body: Encodable { let addressee_id: String; let mode: String }
        struct Ignored: Decodable {}
        _ = try await client.fetch(Ignored.self, path: "/connections/request", method: "POST", token: try token(),
                                   bodyData: try JSONEncoder().encode(Body(addressee_id: userId, mode: mode.rawValue)))
    }

    private func token() throws -> String {
        guard let token = KeychainHelper.load(forKey: KeychainHelper.tokenKey) else {
            throw APIError.serverError(statusCode: 401, message: "Not authenticated")
        }
        return token
    }
}

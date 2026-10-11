import Foundation

/// `/api/muted-words` — HTTP + decoding only.
struct MutedWordsRepository {
    private let client = NetworkClient.shared

    func list(mode: AppMode) async throws -> [MutedWord] {
        try await client.fetch(DataResponse<[MutedWord]>.self, path: "/muted-words", token: try token(),
                               queryItems: [URLQueryItem(name: "mode", value: mode.rawValue)]).data
    }

    func add(_ word: String, duration: MuteDuration, mode: AppMode) async throws -> MutedWord {
        struct Body: Encodable { let word: String; let duration: String; let mode: String }
        return try await client.fetch(MutedWord.self, path: "/muted-words", method: "POST", token: try token(),
                                      bodyData: try JSONEncoder().encode(Body(word: word, duration: duration.rawValue,
                                                                              mode: mode.rawValue)))
    }

    func delete(_ id: String) async throws {
        struct OK: Decodable { let ok: Bool }
        _ = try await client.fetch(OK.self, path: "/muted-words/\(id)", method: "DELETE", token: try token())
    }

    /// Returns how many words were added (ones already there are skipped).
    func copy(from: AppMode, to: AppMode) async throws -> Int {
        struct Body: Encodable { let from: String; let to: String }
        struct Added: Decodable { let added: Int }
        return try await client.fetch(Added.self, path: "/muted-words/copy", method: "POST", token: try token(),
                                      bodyData: try JSONEncoder().encode(Body(from: from.rawValue, to: to.rawValue))).added
    }

    private func token() throws -> String {
        guard let token = KeychainHelper.load(forKey: KeychainHelper.tokenKey) else {
            throw APIError.serverError(statusCode: 401, message: "Not authenticated")
        }
        return token
    }
}

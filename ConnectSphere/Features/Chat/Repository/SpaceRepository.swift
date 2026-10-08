import Foundation

/// `/api/spaces` — HTTP + decoding only.
struct SpaceRepository {
    private let client = NetworkClient.shared

    private struct ListResponse: Decodable { let data: [ChatSpace] }

    func list(mode: String, token: String) async throws -> [ChatSpace] {
        try await client.fetch(ListResponse.self, path: "/spaces", token: token,
                               queryItems: [URLQueryItem(name: "mode", value: mode)]).data
    }

    func create(name: String, color: SpaceColor, mode: String, memberIds: [String], groupIds: [String],
                token: String) async throws -> ChatSpace {
        struct Body: Encodable {
            let name: String; let color: String; let mode: String
            let member_ids: [String]; let conversation_ids: [String]
        }
        return try await client.fetch(ChatSpace.self, path: "/spaces", method: "POST", token: token,
                                      bodyData: try JSONEncoder().encode(Body(name: name, color: color.rawValue, mode: mode,
                                                                              member_ids: memberIds, conversation_ids: groupIds)))
    }

    func update(_ id: String, name: String?, color: SpaceColor?, token: String) async throws -> ChatSpace {
        struct Body: Encodable { let name: String?; let color: String? }
        return try await client.fetch(ChatSpace.self, path: "/spaces/\(id)", method: "PATCH", token: token,
                                      bodyData: try JSONEncoder().encode(Body(name: name, color: color?.rawValue)))
    }

    func delete(_ id: String, token: String) async throws {
        struct OK: Decodable { let ok: Bool }
        _ = try await client.fetch(OK.self, path: "/spaces/\(id)", method: "DELETE", token: token)
    }

    func setMembers(_ id: String, memberIds: [String], groupIds: [String], token: String) async throws -> ChatSpace {
        struct Body: Encodable { let member_ids: [String]; let conversation_ids: [String] }
        return try await client.fetch(ChatSpace.self, path: "/spaces/\(id)/members", method: "PUT", token: token,
                                      bodyData: try JSONEncoder().encode(Body(member_ids: memberIds, conversation_ids: groupIds)))
    }

    func addMember(_ id: String, userId: String, token: String) async throws -> ChatSpace {
        try await client.fetch(ChatSpace.self, path: "/spaces/\(id)/members/\(userId)", method: "POST", token: token)
    }

    func removeMember(_ id: String, userId: String, token: String) async throws -> ChatSpace {
        try await client.fetch(ChatSpace.self, path: "/spaces/\(id)/members/\(userId)", method: "DELETE", token: token)
    }

    func addGroup(_ id: String, conversationId: String, token: String) async throws -> ChatSpace {
        try await client.fetch(ChatSpace.self, path: "/spaces/\(id)/groups/\(conversationId)", method: "POST", token: token)
    }

    func removeGroup(_ id: String, conversationId: String, token: String) async throws -> ChatSpace {
        try await client.fetch(ChatSpace.self, path: "/spaces/\(id)/groups/\(conversationId)", method: "DELETE", token: token)
    }
}

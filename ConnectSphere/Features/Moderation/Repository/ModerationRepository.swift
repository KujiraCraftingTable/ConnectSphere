import Foundation

/// Account status, appeals, and the admin review queue (server migration 089)
/// — HTTP and decoding only.
struct ModerationRepository {
    private let client = NetworkClient.shared
    private struct DataBox<T: Decodable>: Decodable { let data: T }
    private struct Received: Decodable {}

    private func token() throws -> String {
        guard let token = KeychainHelper.load(forKey: KeychainHelper.tokenKey) else {
            throw APIError.serverError(statusCode: 401, message: "Not authenticated")
        }
        return token
    }

    func accountStatus() async throws -> AccountStatus {
        try await client.fetch(DataBox<AccountStatus>.self, path: "/account-status", token: try token()).data
    }

    func appeal(caseId: String, message: String?) async throws {
        var body: [String: Any] = ["case_id": caseId]
        if let message { body["message"] = message }
        _ = try await client.fetch(Received.self, path: "/appeals", method: "POST", token: try token(),
                                   bodyData: try JSONSerialization.data(withJSONObject: body))
    }

    // MARK: admin

    /// `source`: "report" or "auto"; nil for both.
    func cases(source: String?, status: String = "open") async throws -> [ModerationCase] {
        var query = [URLQueryItem(name: "status", value: status), URLQueryItem(name: "limit", value: "50")]
        if let source { query.append(URLQueryItem(name: "source", value: source)) }
        return try await client.fetch(DataBox<[ModerationCase]>.self, path: "/admin/moderation/cases",
                                      token: try token(), queryItems: query).data
    }

    func caseDetail(_ id: String) async throws -> ModerationCaseDetail {
        try await client.fetch(DataBox<ModerationCaseDetail>.self, path: "/admin/moderation/cases/\(id)", token: try token()).data
    }

    func decide(caseId: String, decision: ModerationDecisionKind, hours: Int?, note: String?,
                reporterMessage: String?) async throws -> ModerationCaseDetail {
        var body: [String: Any] = ["decision": decision.rawValue]
        if let hours { body["hours"] = hours }
        if let note { body["note"] = note }
        if let reporterMessage { body["reporter_message"] = reporterMessage }
        return try await client.fetch(DataBox<ModerationCaseDetail>.self, path: "/admin/moderation/cases/\(caseId)/decide",
                                      method: "POST", token: try token(),
                                      bodyData: try JSONSerialization.data(withJSONObject: body)).data
    }

    func appeals() async throws -> [ModerationAppealItem] {
        try await client.fetch(DataBox<[ModerationAppealItem]>.self, path: "/admin/moderation/appeals",
                               token: try token(), queryItems: [URLQueryItem(name: "status", value: "pending")]).data
    }

    func decideAppeal(_ appealId: String, overturn: Bool, note: String?,
                      reporterMessage: String?) async throws -> ModerationCaseDetail {
        var body: [String: Any] = ["result": overturn ? "overturn" : "uphold"]
        if let note { body["note"] = note }
        if let reporterMessage { body["reporter_message"] = reporterMessage }
        return try await client.fetch(DataBox<ModerationCaseDetail>.self, path: "/admin/moderation/appeals/\(appealId)/decide",
                                      method: "POST", token: try token(),
                                      bodyData: try JSONSerialization.data(withJSONObject: body)).data
    }

    // MARK: admin tools (the official account only)

    func adminStats() async throws -> AdminStats {
        try await client.fetch(DataBox<AdminStats>.self, path: "/admin/stats", token: try token()).data
    }

    func lookupUser(_ username: String) async throws -> AdminUserLookup {
        try await client.fetch(DataBox<AdminUserLookup>.self, path: "/admin/users/lookup", token: try token(),
                               queryItems: [URLQueryItem(name: "username", value: username)]).data
    }

    struct Moderated: Decodable { let decision: String; let activeWarnings: Int
        enum CodingKeys: String, CodingKey { case decision, activeWarnings = "active_warnings" } }
    struct WarningCount: Decodable { let activeWarnings: Int; let banned: Bool
        enum CodingKeys: String, CodingKey { case banned, activeWarnings = "active_warnings" } }

    /// The official account bans or warns from a post, comment, message or
    /// profile (server opens a case). `days`: nil is a permanent ban.
    func moderate(action: String, targetType: String, targetId: String, mode: String?,
                  policy: String, days: Int?, note: String?) async throws -> Moderated {
        var body: [String: Any] = ["action": action, "target_type": targetType, "target_id": targetId, "policy": policy]
        if let mode { body["mode"] = mode }
        if let days { body["days"] = days }
        if let note, !note.isEmpty { body["note"] = note }
        return try await client.fetch(Moderated.self, path: "/admin/moderate", method: "POST", token: try token(),
                                      bodyData: try JSONSerialization.data(withJSONObject: body))
    }

    func warningCount(userId: String, mode: String) async throws -> WarningCount {
        try await client.fetch(WarningCount.self, path: "/admin/warnings", token: try token(),
                               queryItems: [URLQueryItem(name: "user_id", value: userId), URLQueryItem(name: "mode", value: mode)])
    }
}

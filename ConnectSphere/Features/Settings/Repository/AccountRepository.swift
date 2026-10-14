import Foundation

/// Verified email and deleting a persona / the account. HTTP + decoding only;
/// every deletion is confirmed with a code emailed to the verified address.
struct AccountRepository {
    private let client = NetworkClient.shared

    enum Scope: String { case hobby, work, account }

    struct Sent: Decodable {
        let email: String
        let expiresInMinutes: Int
        enum CodingKeys: String, CodingKey {
            case email
            case expiresInMinutes = "expires_in_minutes"
        }
    }
    private struct Verified: Decodable { let email: String }
    private struct PersonaDeleted: Decodable {
        let defaultMode: String
        enum CodingKeys: String, CodingKey { case defaultMode = "default_mode" }
    }

    private func body(_ dict: [String: String]) throws -> Data { try JSONSerialization.data(withJSONObject: dict) }

    /// A code to `email` (the address being verified).
    func sendEmailCode(to email: String, token: String) async throws -> Sent {
        try await client.fetch(Sent.self, path: "/users/me/email/code", method: "POST", token: token,
                               bodyData: try body(["email": email]))
    }

    /// Replacing a verified email: a code to the current address first.
    func sendChangeCode(token: String) async throws -> Sent {
        try await client.fetch(Sent.self, path: "/users/me/email/change-code", method: "POST", token: token,
                               bodyData: try body([:]))
    }

    /// The verified address.
    func verifyEmail(code: String, currentCode: String?, token: String) async throws -> String {
        var dict = ["code": code]
        if let currentCode { dict["current_code"] = currentCode }
        return try await client.fetch(Verified.self, path: "/users/me/email/verify", method: "POST", token: token,
                                      bodyData: try body(dict)).email
    }

    func sendDeletionCode(_ scope: Scope, token: String) async throws -> Sent {
        try await client.fetch(Sent.self, path: "/users/me/deletion/code", method: "POST", token: token,
                               bodyData: try body(["scope": scope.rawValue]))
    }

    /// The mode the account is left in.
    func deletePersona(_ mode: AppMode, code: String, token: String) async throws -> AppMode {
        let r = try await client.fetch(PersonaDeleted.self, path: "/users/me/personas/\(mode.rawValue)", method: "DELETE",
                                       token: token, bodyData: try body(["code": code]))
        return AppMode(rawValue: r.defaultMode) ?? (mode == .hobby ? .work : .hobby)
    }

    func deleteAccount(code: String, token: String) async throws {
        _ = try await client.fetch(OKResponse.self, path: "/users/me", method: "DELETE", token: token,
                                   bodyData: try body(["code": code]))
    }
}

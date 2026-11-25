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

    // MARK: - Email
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

    /// Step 1 of replacing a verified email: the current address's code
    /// unlocks the change for a while.
    func confirmChange(code: String, token: String) async throws {
        _ = try await client.fetch(OKResponse.self, path: "/users/me/email/change-confirm", method: "POST", token: token,
                                   bodyData: try body(["code": code]))
    }

    /// The verified address.
    func verifyEmail(code: String, token: String) async throws -> String {
        try await client.fetch(Verified.self, path: "/users/me/email/verify", method: "POST", token: token,
                               bodyData: try body(["code": code])).email
    }

    // MARK: - Username & two-factor
    /// A new @username (once per 6 months); the updated user.
    func changeUsername(_ username: String, token: String) async throws -> AuthUserDTO {
        try await client.fetch(MeResponse.self, path: "/users/me/username", method: "PATCH", token: token,
                               bodyData: try body(["username": username])).user
    }

    /// A code for turning two-factor sign-in on or off.
    func sendTwoFactorCode(token: String) async throws -> Sent {
        try await client.fetch(Sent.self, path: "/users/me/two-factor/code", method: "POST", token: token,
                               bodyData: try body([:]))
    }

    func setTwoFactor(_ enabled: Bool, code: String, token: String) async throws {
        let data = try JSONSerialization.data(withJSONObject: ["enabled": enabled, "code": code])
        struct State: Decodable { let two_factor_enabled: Bool }
        _ = try await client.fetch(State.self, path: "/users/me/two-factor", method: "PATCH", token: token, bodyData: data)
    }

    // MARK: - Deletion & export
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

    func sendExportCode(token: String) async throws -> Sent {
        try await client.fetch(Sent.self, path: "/users/me/export/code", method: "POST", token: token, bodyData: try body([:]))
    }

    /// The person's data as the server's JSON file, confirmed with the emailed
    /// `code` (or, with no verified email, the `password`).
    func exportData(code: String, password: String?, token: String) async throws -> Data {
        struct AnyJSON: Decodable {}
        var fields = ["code": code]
        if let password { fields["password"] = password }
        return try await client.fetchRaw(AnyJSON.self, path: "/users/me/export", method: "POST", token: token,
                                         bodyData: try body(fields)).body
    }

    /// With a verified email the emailed `code` confirms; without one, the `password` does.
    func deleteAccount(code: String, password: String?, token: String) async throws {
        var fields = ["code": code]
        if let password { fields["password"] = password }
        _ = try await client.fetch(OKResponse.self, path: "/users/me", method: "DELETE", token: token,
                                   bodyData: try body(fields))
    }
}

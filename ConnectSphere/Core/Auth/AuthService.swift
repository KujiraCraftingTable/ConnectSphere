import Foundation
import Observation

/// Handles all authentication API calls.
/// DTOs live in AuthDTOs.swift; HTTP transport is handled by NetworkClient.
@MainActor
@Observable
class AuthService {
    static let shared = AuthService()
    private let client = NetworkClient.shared
    private init() {}

    func signInWithGoogle(idToken: String) async throws -> AuthResponse {
        guard let url = URL(string: APIConfig.baseURL + "/auth/google") else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(["id_token": idToken])

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if http.statusCode != 200 {
            throw NSError(domain: "Auth", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: Self.serverErrorMessage(from: data)])
        }
        return try JSONDecoder.makeISO8601().decode(AuthResponse.self, from: data)
    }

    /// Reads the error message from the server body, tolerating both formats:
    /// a route returning `{error}` and the central errorHandler returning `{status, code, message}`
    /// (decoding as [String: String] would fail entirely since `code` is a number → losing the real message).
    private static func serverErrorMessage(from data: Data) -> String {
        let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return (dict?["error"] as? String) ?? (dict?["message"] as? String) ?? "Auth failed"
    }

    // MARK: - Username / password auth

    func register(username: String, password: String) async throws -> AuthResponse {
        try await passwordAuth(path: "/auth/register", username: username, password: password)
    }

    func login(username: String, password: String) async throws -> AuthResponse {
        try await passwordAuth(path: "/auth/login", username: username, password: password)
    }

    /// Calls the username/password auth endpoint; errors throw NSError with code = HTTP status
    /// so the caller can map it to a localized message (409 duplicate username, 401 wrong password…).
    private func passwordAuth(path: String, username: String, password: String) async throws -> AuthResponse {
        guard let url = URL(string: APIConfig.baseURL + path) else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(["username": username, "password": password])

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200...299).contains(http.statusCode) else {
            throw NSError(domain: "Auth", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: Self.serverErrorMessage(from: data)])
        }
        return try JSONDecoder.makeISO8601().decode(AuthResponse.self, from: data)
    }

    func fetchMe(token: String) async throws -> AuthUserDTO {
        guard let url = URL(string: APIConfig.baseURL + "/auth/me") else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            // Distinguish 401 (genuinely invalid token) from other errors (server trouble) —
            // the caller should only delete the Keychain token on a 401
            guard http.statusCode != 401 else { throw URLError(.userAuthenticationRequired) }
            guard http.statusCode == 200 else { throw URLError(.badServerResponse) }
            let user = try JSONDecoder.makeISO8601().decode(MeResponse.self, from: data).user
            await CacheStore.shared.put(CacheStore.Key.me, body: data)   // for an offline cold launch
            return user
        } catch let err as URLError where err.code != .userAuthenticationRequired {
            // Offline / server down (not a 401) — restore the last-known profile
            // so the app opens to its cached state instead of the login screen.
            if let cached = await CacheStore.shared.get(MeResponse.self, CacheStore.Key.me) {
                return cached.user
            }
            throw err
        }
    }

    // MARK: - Password management

    /// Changes the password (Google accounts have no password yet: first-time set, currentPassword = nil)
    func changePassword(token: String, currentPassword: String?, newPassword: String) async throws {
        var body = ["new_password": newPassword]
        if let currentPassword { body["current_password"] = currentPassword }
        try await postJSON(path: "/auth/change-password", body: body, token: token)
    }

    /// Requests a password-reset OTP (sent to the account's email if one exists)
    func forgotPassword(identifier: String) async throws {
        try await postJSON(path: "/auth/forgot-password", body: ["identifier": identifier])
    }

    /// Resets the password using the OTP received via email
    func resetPassword(identifier: String, otp: String, newPassword: String) async throws {
        try await postJSON(path: "/auth/reset-password",
                           body: ["identifier": identifier, "otp": otp, "new_password": newPassword])
    }

    /// Shared POST JSON helper for the secondary auth endpoints;
    /// errors throw NSError with code = HTTP status so the caller can map it to a localized message.
    private func postJSON(path: String, body: [String: String], token: String? = nil) async throws {
        guard let url = URL(string: APIConfig.baseURL + path) else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        req.httpBody = try JSONEncoder().encode(body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200...299).contains(http.statusCode) else {
            let msg = (try? JSONDecoder().decode([String: String].self, from: data))?["error"] ?? "Request failed"
            throw NSError(domain: "Auth", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: msg])
        }
    }

    func setup(token: String, form: OnboardingForm) async throws -> AuthUserDTO {
        guard let url = URL(string: APIConfig.baseURL + "/auth/setup") else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONEncoder().encode(form)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if http.statusCode != 200 {
            let msg = (try? JSONDecoder().decode([String: String].self, from: data))?["error"] ?? "Setup failed"
            throw NSError(domain: "Auth", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: msg])
        }
        struct Wrap: Decodable { let user: AuthUserDTO }
        return try JSONDecoder.makeISO8601().decode(Wrap.self, from: data).user
    }
}

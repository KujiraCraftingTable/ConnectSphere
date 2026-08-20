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

    /// Đọc message lỗi từ body server, chịu được cả 2 format:
    /// route trả `{error}` và errorHandler trung tâm trả `{status, code, message}`
    /// (decode [String: String] sẽ fail toàn bộ vì `code` là số → mất message thật).
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

    /// Gọi endpoint auth username/password; lỗi ném NSError với code = HTTP status
    /// để caller map sang thông báo đã localize (409 trùng username, 401 sai pass…).
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
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        // Phân biệt 401 (token hỏng thật) với lỗi khác (server sự cố) —
        // caller chỉ được xoá token Keychain khi 401
        guard http.statusCode != 401 else { throw URLError(.userAuthenticationRequired) }
        guard http.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try JSONDecoder.makeISO8601().decode(MeResponse.self, from: data).user
    }

    /// Realtime check dùng ở bước onboarding — trả về true nếu username còn trống.
    func checkUsernameAvailable(token: String, username: String) async throws -> Bool {
        var components = URLComponents(string: APIConfig.baseURL + "/auth/check-username")
        components?.queryItems = [URLQueryItem(name: "username", value: username)]
        guard let url = components?.url else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        struct Wrap: Decodable { let available: Bool }
        return try JSONDecoder().decode(Wrap.self, from: data).available
    }

    // MARK: - Password management

    /// Đổi mật khẩu (tài khoản Google chưa có mật khẩu: đặt lần đầu, currentPassword = nil)
    func changePassword(token: String, currentPassword: String?, newPassword: String) async throws {
        var body = ["new_password": newPassword]
        if let currentPassword { body["current_password"] = currentPassword }
        try await postJSON(path: "/auth/change-password", body: body, token: token)
    }

    /// Yêu cầu OTP đặt lại mật khẩu (gửi tới email của tài khoản nếu có)
    func forgotPassword(identifier: String) async throws {
        try await postJSON(path: "/auth/forgot-password", body: ["identifier": identifier])
    }

    /// Đặt lại mật khẩu bằng OTP nhận qua email
    func resetPassword(identifier: String, otp: String, newPassword: String) async throws {
        try await postJSON(path: "/auth/reset-password",
                           body: ["identifier": identifier, "otp": otp, "new_password": newPassword])
    }

    /// POST JSON dùng chung cho nhóm endpoint auth phụ;
    /// lỗi ném NSError với code = HTTP status để caller map sang message localize.
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

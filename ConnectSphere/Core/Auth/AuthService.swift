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
            let msg = (try? JSONDecoder().decode([String: String].self, from: data))?["error"] ?? "Auth failed"
            throw NSError(domain: "Auth", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: msg])
        }
        return try JSONDecoder.makeISO8601().decode(AuthResponse.self, from: data)
    }

    func fetchMe(token: String) async throws -> AuthUserDTO {
        guard let url = URL(string: APIConfig.baseURL + "/auth/me") else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.userAuthenticationRequired)
        }
        return try JSONDecoder.makeISO8601().decode(MeResponse.self, from: data).user
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

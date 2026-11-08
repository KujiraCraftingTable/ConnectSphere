import Foundation
import Observation
import UIKit

/// With two-factor on, a sign-in answers with this instead of a token: the
/// code went to `email` (masked); send it back with `challenge`.
struct LoginChallenge: Decodable, Equatable {
    let challenge: String
    let email: String
}

enum LoginResult {
    case signedIn(AuthResponse)
    case needsCode(LoginChallenge)
}

/// Handles all authentication API calls.
/// DTOs live in AuthDTOs.swift; HTTP transport is handled by NetworkClient.
@MainActor
@Observable
class AuthService {
    static let shared = AuthService()
    private let client = NetworkClient.shared
    private init() {}

    /// What the sign-in alert says the device is: "iPhone 17 · iOS 27.0". Sent
    /// percent-encoded: an HTTP header is ASCII, and the "·" arrived as "�".
    private static var deviceName: String {
        let text = "\(DeviceModel.current) · \(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"
        return text.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: " .-_()"))) ?? text
    }

    /// POSTs a JSON body to an auth endpoint; errors throw NSError with
    /// code = HTTP status so callers can map them to localized messages.
    private func post(_ path: String, _ body: [String: String]) async throws -> Data {
        try await post(path, json: JSONEncoder().encode(body))
    }

    private func post(_ path: String, json: Data) async throws -> Data {
        guard let url = URL(string: APIConfig.baseURL + path) else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(Self.deviceName, forHTTPHeaderField: "X-Device")
        req.httpBody = json
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200...299).contains(http.statusCode) else {
            throw NSError(domain: "Auth", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: Self.serverErrorMessage(from: data)])
        }
        return data
    }

    /// A token, or, with two-factor on, a code challenge.
    private func signInResult(_ data: Data) throws -> LoginResult {
        let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if dict?["two_factor_required"] as? Bool == true {
            return .needsCode(try JSONDecoder().decode(LoginChallenge.self, from: data))
        }
        return .signedIn(try JSONDecoder.makeISO8601().decode(AuthResponse.self, from: data))
    }

    func signInWithGoogle(idToken: String) async throws -> LoginResult {
        try signInResult(try await post("/auth/google", ["id_token": idToken]))
    }

    /// The emailed code for a two-factor sign-in.
    func verifyLogin(challenge: String, code: String) async throws -> AuthResponse {
        try JSONDecoder.makeISO8601().decode(AuthResponse.self,
                                             from: try await post("/auth/login/verify", ["challenge": challenge, "code": code]))
    }

    /// A fresh code (and challenge) for the same sign-in.
    func resendLogin(challenge: String) async throws -> LoginChallenge {
        try JSONDecoder().decode(LoginChallenge.self, from: try await post("/auth/login/resend", ["challenge": challenge]))
    }

    /// Reads the error message from the server body, tolerating both formats:
    /// a route returning `{error}` and the central errorHandler returning `{status, code, message}`
    /// (decoding as [String: String] would fail entirely since `code` is a number → losing the real message).
    private static func serverErrorMessage(from data: Data) -> String {
        let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return (dict?["error"] as? String) ?? (dict?["message"] as? String) ?? "Auth failed"
    }

    // MARK: - Username / password auth

    /// A new account never has two-factor on yet.
    /// Checks the username and email are free, then emails a sign-up code.
    func registerCode(username: String, email: String) async throws {
        _ = try await post("/auth/register/code", ["username": username, "email": email])
    }

    /// Confirms the sign-up email with its code (kept for an hour, until
    /// onboarding finishes and the account is created).
    func registerVerify(email: String, code: String) async throws {
        _ = try await post("/auth/register/verify", ["email": email, "code": code])
    }

    /// Creates the account with everything onboarding collected.
    func register(_ signup: PendingSignup, form: OnboardingForm) async throws -> AuthResponse {
        var body = (try JSONSerialization.jsonObject(with: JSONEncoder().encode(form))) as? [String: Any] ?? [:]
        body["username"] = signup.username
        body["password"] = signup.password
        if let email = signup.email { body["email"] = email }
        return try JSONDecoder.makeISO8601().decode(AuthResponse.self,
                                                     from: try await post("/auth/register", json: JSONSerialization.data(withJSONObject: body)))
    }

    /// Free to sign up with? No session needed (usernames are public).
    func usernameAvailable(_ username: String) async throws -> Bool {
        var comps = URLComponents(string: APIConfig.baseURL + "/auth/username-available")
        comps?.queryItems = [URLQueryItem(name: "username", value: username)]
        guard let url = comps?.url else { throw URLError(.badURL) }
        let (data, resp) = try await URLSession.shared.data(from: url)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        struct Available: Decodable { let available: Bool }
        return try JSONDecoder().decode(Available.self, from: data).available
    }

    /// `identifier` is the @username or the email.
    func login(identifier: String, password: String) async throws -> LoginResult {
        try signInResult(try await post("/auth/login", ["username": identifier, "password": password]))
    }

    /// The last profile `/auth/me` returned, for opening the app without
    /// waiting on the server.
    func cachedMe() -> AuthUserDTO? {
        CacheStore.shared.get(MeResponse.self, CacheStore.Key.me)?.user
    }

    /// `mode` asks for that mode's persona; nil is the account's default mode.
    /// `cacheFallback` returns the cached profile when the server can't be
    /// reached (not on a 401).
    func fetchMe(token: String, mode: AppMode? = nil, cacheFallback: Bool = true) async throws -> AuthUserDTO {
        var comps = URLComponents(string: APIConfig.baseURL + "/auth/me")
        if let mode { comps?.queryItems = [URLQueryItem(name: "mode", value: mode.rawValue)] }
        guard let url = comps?.url else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        // The default 60 s held the launch splash for a minute whenever the
        // server was busy with Ollama work.
        req.timeoutInterval = 10
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            // Distinguish 401 (genuinely invalid token) from other errors (server trouble),
            // the caller should only delete the Keychain token on a 401
            guard http.statusCode != 401 else { throw URLError(.userAuthenticationRequired) }
            if http.statusCode == 403 {
                AccountSuspension.check(statusCode: 403, message: (try? JSONDecoder().decode(ErrorResponse.self, from: data))?.message)
            }
            guard http.statusCode == 200 else { throw URLError(.badServerResponse) }
            let user = try JSONDecoder.makeISO8601().decode(MeResponse.self, from: data).user
            // The cold-launch cache is the default-mode profile; a per-mode
            // fetch must not replace it.
            if mode == nil { await CacheStore.shared.put(CacheStore.Key.me, body: data) }   // for an offline cold launch
            return user
        } catch let err as URLError where err.code != .userAuthenticationRequired && mode == nil && cacheFallback {
            // Offline / server down (not a 401). Restore the last-known profile
            // so the app opens to its cached state instead of the login screen.
            if let cached = await CacheStore.shared.get(MeResponse.self, CacheStore.Key.me) {
                return cached.user
            }
            throw err
        }
    }

    // MARK: - Password management

    /// Changes the password (Google accounts have no password yet: first-time set, currentPassword = nil).
    /// Every older session ends with the change, so the server returns the token this device keeps using.
    func changePassword(token: String, currentPassword: String?, newPassword: String) async throws -> String {
        var body = ["new_password": newPassword]
        if let currentPassword { body["current_password"] = currentPassword }
        let data = try await postJSON(path: "/auth/change-password", body: body, token: token)
        struct Reply: Decodable { let token: String }
        return try JSONDecoder().decode(Reply.self, from: data).token
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
    @discardableResult
    private func postJSON(path: String, body: [String: String], token: String? = nil) async throws -> Data {
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
        return data
    }

    /// Whether `username` is free (the caller's own current name counts as free).
    func isUsernameAvailable(_ username: String, token: String) async throws -> Bool {
        var comps = URLComponents(string: APIConfig.baseURL + "/auth/check-username")
        comps?.queryItems = [URLQueryItem(name: "username", value: username)]
        guard let url = comps?.url else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        struct Available: Decodable { let available: Bool }
        return try JSONDecoder().decode(Available.self, from: data).available
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
            throw NSError(domain: "Auth", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: Self.serverErrorMessage(from: data)])
        }
        struct Wrap: Decodable { let user: AuthUserDTO }
        return try JSONDecoder.makeISO8601().decode(Wrap.self, from: data).user
    }
}

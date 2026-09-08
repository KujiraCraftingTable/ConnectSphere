import Vapor
import AsyncHTTPClient

/// Port of the Google verification in `POST /api/auth/google` — a raw call to
/// Google's `tokeninfo` endpoint (no google-auth-library), with the same `aud`
/// and `email_verified` checks and the same 10s timeout.
enum GoogleAuth {
    struct TokenInfo: Content {
        var sub: String?
        var email: String?
        var email_verified: String?   // Google returns "true"/"false" as strings here
        var aud: String?
        var name: String?
        var picture: String?
    }

    enum GoogleError: Error {
        case invalidToken
        case notConfigured        // prod + no GOOGLE_CLIENT_ID → 503
        case emailNotVerified
        case missingUserInfo
    }

    /// Verifies `idToken`. Throws `GoogleError` mapped to the right status by the
    /// caller. `clientId` empty + non-prod → `aud` check skipped (dev only).
    static func verify(idToken: String, clientId: String, isProduction: Bool, client: HTTPClient, logger: Logger) async throws -> TokenInfo {
        var request = HTTPClientRequest(url: "https://oauth2.googleapis.com/tokeninfo?id_token=\(idToken)")
        request.method = .GET
        let response: HTTPClientResponse
        do {
            response = try await client.execute(request, timeout: .seconds(10))
        } catch {
            throw GoogleError.invalidToken
        }
        guard (200..<300).contains(Int(response.status.code)) else {
            throw GoogleError.invalidToken
        }
        let body = try await response.body.collect(upTo: 64 * 1024)
        let info: TokenInfo
        do {
            info = try JSONCoding.makeDecoder().decode(TokenInfo.self, from: Data(buffer: body))
        } catch {
            throw GoogleError.invalidToken
        }

        if !clientId.isEmpty {
            guard info.aud == clientId else {
                logger.warning("Google token aud mismatch — rejected (aud=\(info.aud ?? "nil"))")
                throw GoogleError.invalidToken
            }
        } else if isProduction {
            logger.error("GOOGLE_CLIENT_ID is not set — refusing Google sign-in in production")
            throw GoogleError.notConfigured
        } else {
            logger.warning("GOOGLE_CLIENT_ID not set — skipping aud check (dev only)")
        }

        if info.email_verified == "false" {
            throw GoogleError.emailNotVerified
        }
        guard let sub = info.sub, !sub.isEmpty, let email = info.email, !email.isEmpty else {
            throw GoogleError.missingUserInfo
        }
        _ = (sub, email)
        return info
    }
}

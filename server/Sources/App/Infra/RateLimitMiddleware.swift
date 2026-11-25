import Vapor
import NIOConcurrencyHelpers

/// In-memory fixed-window rate limiter. Counts are per-process and reset on
/// restart (no Redis store).
///
/// - global: 1000 / 15 min on every route.
/// - `passwordAuth()`: 10 / 15 min, body `{ "error": "Too many attempts, please try again later" }`.
/// - `clarify()`: 20 / 15 min.
struct RateLimitMiddleware: AsyncMiddleware {
    /// Keeps each limiter's counts apart. They share one store, so without it
    /// the global limiter and a route's own limiter bumped the same counter and
    /// every request counted twice (the real limits were half the stated ones).
    let name: String
    let max: Int
    let windowSeconds: Double
    let inlineErrorBody: Bool
    let message: String

    private static let store = Store()

    // MARK: - Limits
    static func global() -> RateLimitMiddleware {
        .init(name: "global", max: loadTest ? 1_000_000 : 1000, windowSeconds: 15 * 60, inlineErrorBody: false,
              message: "Too many requests, please try again later")
    }
    static func passwordAuth() -> RateLimitMiddleware {
        .init(name: "password", max: uitestHooks ? 200 : 10, windowSeconds: 15 * 60, inlineErrorBody: true,
              message: "Too many attempts, please try again later")
    }

    /// The UI-test server (`UITEST_HOOKS=1`, loopback only) signs in many
    /// times a run from 127.0.0.1; 10 per 15 min would fail the suite midway.
    private static let uitestHooks = Environment.get("UITEST_HOOKS") == "1"
    /// `scripts/loadtest.sh`: thousands of requests from 127.0.0.1 in minutes.
    /// Only with the loopback-only test hooks on too, so a stray LOAD_TEST on
    /// a real server changes nothing.
    private static let loadTest = uitestHooks && Environment.get("LOAD_TEST") == "1"
    /// Emailed codes (verify email, delete a persona / the account).
    static func accountCodes() -> RateLimitMiddleware {
        .init(name: "codes", max: 20, windowSeconds: 15 * 60, inlineErrorBody: false,
              message: "Too many attempts, please try again later")
    }
    static func clarify() -> RateLimitMiddleware {
        .init(name: "clarify", max: 20, windowSeconds: 15 * 60, inlineErrorBody: true,
              message: "Too many requests, please try again later")
    }
    /// Reports: generous for a real user, but stops one account flooding the
    /// moderation queue against someone.
    static func reports() -> RateLimitMiddleware {
        .init(name: "reports", max: 30, windowSeconds: 15 * 60, inlineErrorBody: true,
              message: "Too many reports, please try again later")
    }
    /// The admin's stats and account lookup: plenty for one person, but a
    /// stolen admin token can't page through every account.
    static func admin() -> RateLimitMiddleware {
        .init(name: "admin", max: 120, windowSeconds: 15 * 60, inlineErrorBody: true,
              message: "Too many requests, please try again later")
    }
    /// The Ollama-bound `/api/search/ai` is capped per client.
    static func aiSearch() -> RateLimitMiddleware {
        .init(name: "ai-search", max: loadTest ? 100_000 : 30, windowSeconds: 15 * 60, inlineErrorBody: false,
              message: "Too many searches, please slow down")
    }

    // MARK: - Middleware
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        let key = "\(name):\(request.route?.description ?? request.url.path):\(clientIP(request))"
        let (count, resetIn) = Self.store.hit(key: key, windowSeconds: windowSeconds)
        if count > max {
            if inlineErrorBody {
                throw InlineError(.tooManyRequests, message)
            }
            throw Abort(.tooManyRequests, reason: message)
        }
        let response = try await next.respond(to: request)
        response.headers.replaceOrAdd(name: "RateLimit-Limit", value: "\(max)")
        response.headers.replaceOrAdd(name: "RateLimit-Remaining", value: "\(Swift.max(0, max - count))")
        response.headers.replaceOrAdd(name: "RateLimit-Reset", value: "\(Int(resetIn))")
        return response
    }

    /// Behind a reverse proxy (`TRUST_PROXY=1`) every request comes from the
    /// proxy, so the client is the first `X-Forwarded-For` entry. Otherwise the
    /// header is whatever the client chose to send, and trusting it let a new
    /// value on each attempt get around the login and code limits.
    private static let trustsProxy = Environment.get("TRUST_PROXY") == "1"

    private func clientIP(_ request: Request) -> String {
        if Self.trustsProxy,
           let forwarded = request.headers.first(name: "X-Forwarded-For")?.split(separator: ",").first {
            return forwarded.trimmingCharacters(in: .whitespaces)
        }
        return request.remoteAddress?.ipAddress ?? "unknown"
    }

    // MARK: - Store
    final class Store: @unchecked Sendable {
        private let lock = NIOLock()
        private var windows: [String: (count: Int, resetAt: Date)] = [:]

        /// The current count without adding to it.
        func peek(key: String) -> (count: Int, resetIn: Double) {
            lock.withLock {
                let now = Date()
                guard let w = windows[key], w.resetAt > now else { return (0, 0) }
                return (w.count, w.resetAt.timeIntervalSince(now))
            }
        }

        func hit(key: String, windowSeconds: Double) -> (count: Int, resetIn: Double) {
            lock.withLock {
                let now = Date()
                if let w = windows[key], w.resetAt > now {
                    let updated = (count: w.count + 1, resetAt: w.resetAt)
                    windows[key] = updated
                    return (updated.count, updated.resetAt.timeIntervalSince(now))
                } else {
                    let resetAt = now.addingTimeInterval(windowSeconds)
                    windows[key] = (count: 1, resetAt: resetAt)
                    return (1, windowSeconds)
                }
            }
        }
    }
}

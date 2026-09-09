import Vapor
import NIOConcurrencyHelpers

/// In-memory fixed-window rate limiter — the Swift counterpart of the
/// `express-rate-limit` instances in the Node backend. Counts are per-process
/// and reset on restart, which matches the Node behaviour (no Redis store).
///
/// - global: 1000 / 15 min on every route.
/// - `passwordAuth()`: 10 / 15 min, body `{ "error": "Too many attempts, please try again later" }`.
/// - `clarify()`: 20 / 15 min.
struct RateLimitMiddleware: AsyncMiddleware {
    let max: Int
    let windowSeconds: Double
    let inlineErrorBody: Bool
    let message: String

    private static let store = Store()

    static func global() -> RateLimitMiddleware {
        .init(max: 1000, windowSeconds: 15 * 60, inlineErrorBody: false,
              message: "Too many requests, please try again later")
    }
    static func passwordAuth() -> RateLimitMiddleware {
        .init(max: 10, windowSeconds: 15 * 60, inlineErrorBody: true,
              message: "Too many attempts, please try again later")
    }
    static func clarify() -> RateLimitMiddleware {
        .init(max: 20, windowSeconds: 15 * 60, inlineErrorBody: true,
              message: "Too many requests, please try again later")
    }
    /// Folded review fix: the Ollama-bound `/api/search/ai` is unthrottled in
    /// Node — cap it per client. Allowlisted divergence.
    static func aiSearch() -> RateLimitMiddleware {
        .init(max: 30, windowSeconds: 15 * 60, inlineErrorBody: false,
              message: "Too many searches, please slow down")
    }

    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        let key = "\(ObjectIdentifier(Self.store).hashValue):\(request.route?.description ?? request.url.path):\(clientIP(request))"
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

    private func clientIP(_ request: Request) -> String {
        request.headers.first(name: "X-Forwarded-For")?.split(separator: ",").first.map(String.init)
            ?? request.remoteAddress?.ipAddress
            ?? "unknown"
    }

    final class Store: @unchecked Sendable {
        private let lock = NIOLock()
        private var windows: [String: (count: Int, resetAt: Date)] = [:]

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

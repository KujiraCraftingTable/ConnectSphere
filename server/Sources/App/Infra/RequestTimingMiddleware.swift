import Vapor

/// Logs how long each API request took, by route pattern (`GET /api/posts/:id`,
/// never the ids themselves), with a warning above `slowAfterMS`. Enough to
/// see which screen is slow and when, without a tracing stack.
struct RequestTimingMiddleware: AsyncMiddleware {
    static let slowAfterMS = 1000.0

    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        let started = ContinuousClock.now
        var status: UInt = 500
        defer {
            let ms = (ContinuousClock.now - started) / .milliseconds(1)
            let route = request.route.map { "/" + $0.path.map(\.description).joined(separator: "/") } ?? request.url.path
            let line: Logger.Message = "\(request.method) \(route) \(status) \(Int(ms)) ms"
            if ms >= Self.slowAfterMS { request.logger.warning("slow request: \(line)") }
            else { request.logger.debug(line) }
        }
        let response = try await next.respond(to: request)
        status = response.status.code
        return response
    }
}

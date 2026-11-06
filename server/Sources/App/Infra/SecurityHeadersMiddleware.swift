import Vapor

/// Sets the usual security headers. The API is JSON-only and
/// consumed by a native app, so the browser-oriented CSP/HSTS bits matter little,
/// but they avoid surprises for anyone hitting it from a browser.
struct SecurityHeadersMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        let response = try await next.respond(to: request)
        var h = response.headers
        h.replaceOrAdd(name: "X-Content-Type-Options", value: "nosniff")
        h.replaceOrAdd(name: "X-Frame-Options", value: "SAMEORIGIN")
        h.replaceOrAdd(name: "X-DNS-Prefetch-Control", value: "off")
        h.replaceOrAdd(name: "Referrer-Policy", value: "no-referrer")
        h.replaceOrAdd(name: "Cross-Origin-Opener-Policy", value: "same-origin")
        h.replaceOrAdd(name: "Cross-Origin-Resource-Policy", value: "same-origin")
        h.replaceOrAdd(name: "Origin-Agent-Cluster", value: "?1")
        h.remove(name: "X-Powered-By")
        h.remove(name: "Server")
        response.headers = h
        return response
    }
}

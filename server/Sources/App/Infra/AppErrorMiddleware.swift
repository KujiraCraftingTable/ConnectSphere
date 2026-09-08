import Vapor

/// Central error handler — the Swift counterpart of
/// `backend/src/middlewares/errorHandler.js`. Emits `{status,code,message}` with
/// 5xx messages scrubbed. Individual handlers that need the inline `{error:"…"}`
/// shape throw `InlineError` instead (see below).
struct AppErrorMiddleware: AsyncMiddleware {
    let isProduction: Bool
    let logger: Logger

    struct StandardBody: Content {
        let status = "error"
        let code: Int
        let message: String
    }
    struct InlineBody: Content {
        let error: String
    }

    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        do {
            return try await next.respond(to: request)
        } catch {
            return handle(error, for: request)
        }
    }

    private func handle(_ error: any Error, for request: Request) -> Response {
        var status: HTTPResponseStatus
        var message: String
        var inline = false

        switch error {
        case let inlineErr as InlineError:
            status = inlineErr.status
            message = inlineErr.reason
            inline = true
        case let abort as any AbortError:
            status = abort.status
            message = abort.reason
        default:
            status = .internalServerError
            message = "Internal Server Error"
        }

        logger.report(error: error)
        logger.error("Request error \(request.method) \(request.url.path) -> \(status.code)")

        let headers = HTTPHeaders([("content-type", "application/json; charset=utf-8")])
        let body: Response.Body
        if inline {
            body = (try? JSONEncoder().encode(InlineBody(error: message))).map { Response.Body(data: $0) } ?? .init(string: #"{"error":"error"}"#)
        } else {
            let safe = status.code < 500 ? message : "Internal Server Error"
            body = (try? JSONEncoder().encode(StandardBody(code: Int(status.code), message: safe)))
                .map { Response.Body(data: $0) } ?? .init(string: #"{"status":"error","code":500,"message":"Internal Server Error"}"#)
        }
        return Response(status: status, headers: headers, body: body)
    }
}

/// Throw this for routes whose Node original responds with `{ "error": "…" }`
/// (auth, connections, users, posts, stories, interactions). Everything else
/// uses `Abort` → the `{status,code,message}` shape.
struct InlineError: Error {
    let status: HTTPResponseStatus
    let reason: String
    init(_ status: HTTPResponseStatus, _ reason: String) {
        self.status = status
        self.reason = reason
    }
}

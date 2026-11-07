import Vapor

/// Central error handler. Emits `{status,code,message}` with
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
    struct StatusMessageBody: Content {
        let status = "error"
        let message: String
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
        var statusMessageOnly = false

        switch error {
        case let inlineErr as InlineError:
            status = inlineErr.status
            message = inlineErr.reason
            inline = true
        case let sm as StatusMessageError:
            status = sm.status
            message = sm.reason
            statusMessageOnly = true
        // Vapor's DecodingError text is Swift's internal wording (key paths,
        // NSCocoaErrorDomain codes), and an empty or unreadable body is a 422
        // with no message. The client sees one plain 400 for both.
        case is DecodingError:
            status = .badRequest
            message = "Invalid request body"
        case let abort as any AbortError where abort.status == .unprocessableEntity:
            status = .badRequest
            message = "Invalid request body"
        case let abort as any AbortError:
            status = abort.status
            message = abort.reason
        default:
            // Postgres "client error" SQLSTATEs → 4xx.
            if PGError.sqlState(error, is: "22P02") {          // invalid_text_representation (bad UUID)
                status = .notFound;   message = "Not found"
            } else if PGError.sqlState(error, is: "22003") {   // numeric_value_out_of_range
                status = .badRequest; message = "Value out of range"
            } else if PGError.sqlState(error, is: "22007") {   // invalid_datetime_format
                status = .badRequest; message = "Invalid date/time"
            } else {
                status = .internalServerError
                message = "Internal Server Error"
            }
        }

        logger.report(error: error)
        logger.error("Request error \(request.method) \(request.url.path) -> \(status.code)")

        let headers = HTTPHeaders([("content-type", "application/json; charset=utf-8")])
        let body: Response.Body
        if inline {
            body = (try? JSONEncoder().encode(InlineBody(error: message))).map { Response.Body(data: $0) } ?? .init(string: #"{"error":"error"}"#)
        } else if statusMessageOnly {
            body = (try? JSONEncoder().encode(StatusMessageBody(message: message))).map { Response.Body(data: $0) } ?? .init(string: #"{"status":"error","message":"error"}"#)
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

/// Throw this for routes whose Node original responds with
/// `{ "status": "error", "message": "…" }`, no `code` (feedController and a
/// few others).
struct StatusMessageError: Error {
    let status: HTTPResponseStatus
    let reason: String
    init(_ status: HTTPResponseStatus, _ reason: String) {
        self.status = status
        self.reason = reason
    }
}

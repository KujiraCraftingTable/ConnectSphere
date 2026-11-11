import Vapor

/// Central error handler. Every error, whatever was thrown, is rendered as
/// `{status,code,message}` with 5xx messages scrubbed: one shape for the client.
struct AppErrorMiddleware: AsyncMiddleware {
    let isProduction: Bool
    let logger: Logger

    struct StandardBody: Content {
        let status = "error"
        let code: Int
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

        switch error {
        case let inlineErr as InlineError:
            status = inlineErr.status
            message = inlineErr.reason
        case let sm as StatusMessageError:
            status = sm.status
            message = sm.reason
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
        let safe = status.code < 500 ? message : "Internal Server Error"
        let body = (try? JSONEncoder().encode(StandardBody(code: Int(status.code), message: safe)))
            .map { Response.Body(data: $0) } ?? .init(string: #"{"status":"error","code":500,"message":"Internal Server Error"}"#)
        return Response(status: status, headers: headers, body: body)
    }
}

/// A 4xx with a message, kept from the Node port (where these routes answered
/// `{ "error": "…" }`); it now renders like `Abort`.
struct InlineError: Error {
    let status: HTTPResponseStatus
    let reason: String
    init(_ status: HTTPResponseStatus, _ reason: String) {
        self.status = status
        self.reason = reason
    }
}

/// Kept from the Node port (feedController answered without `code`); it now
/// renders like `Abort`.
struct StatusMessageError: Error {
    let status: HTTPResponseStatus
    let reason: String
    init(_ status: HTTPResponseStatus, _ reason: String) {
        self.status = status
        self.reason = reason
    }
}

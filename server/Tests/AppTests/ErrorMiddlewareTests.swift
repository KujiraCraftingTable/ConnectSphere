@testable import App
import XCTVapor

/// What the client sees for a body it can't be blamed for reading.
final class ErrorMiddlewareTests: XCTestCase {
    private struct Body: Content { var name: String; var age: Int }

    private func makeApp() async throws -> Application {
        let app = try await Application.make(.testing)
        app.middleware.use(AppErrorMiddleware(isProduction: false, logger: app.logger))
        app.post("echo") { req async throws -> String in try req.content.decode(Body.self).name }
        return app
    }

    func testBadJSONIsAPlain400NotSwiftsDecoderText() async throws {
        let app = try await makeApp()
        defer { Task { try? await app.asyncShutdown() } }
        try await app.test(.POST, "echo", headers: ["content-type": "application/json"],
                           body: ByteBuffer(string: #"{"name":"x","age":"old"}"#)) { res async in
            XCTAssertEqual(res.status, .badRequest)
            XCTAssertTrue(res.body.string.contains("Invalid request body"), res.body.string)
            XCTAssertFalse(res.body.string.contains("Cocoa"))
            XCTAssertFalse(res.body.string.contains("typeMismatch"))
        }
    }

    func testAnEmptyBodyIs400Not422() async throws {
        let app = try await makeApp()
        defer { Task { try? await app.asyncShutdown() } }
        try await app.test(.POST, "echo", headers: ["content-type": "application/json"]) { res async in
            XCTAssertEqual(res.status, .badRequest)
            XCTAssertTrue(res.body.string.contains("Invalid request body"), res.body.string)
        }
    }
}

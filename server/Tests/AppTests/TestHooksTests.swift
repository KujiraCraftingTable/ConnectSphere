import XCTVapor
@testable import App

/// `/api/test` must stay off unless asked for, and locked down when on.
final class TestHooksTests: XCTestCase {
    private let base = ["DB_HOST": "h", "DB_PORT": "5432", "DB_NAME": "d", "DB_USER": "u", "DB_PASSWORD": "p"]
    private let goodToken = String(repeating: "a", count: 32)

    private func env(_ extra: [String: String]) throws -> AppEnv {
        let all = base.merging(extra) { $1 }
        return try AppEnv.load { all[$0] }
    }

    // MARK: config

    func testHooksOffByDefault() throws {
        let e = try env([:])
        XCTAssertFalse(e.uitest.hooksEnabled)
        XCTAssertEqual(e.uitest.token, "")
    }

    func testTokenIgnoredWhenHooksOff() throws {
        XCTAssertEqual(try env(["UITEST_TOKEN": goodToken]).uitest.token, "")
    }

    func testHooksNeedLongToken() {
        XCTAssertThrowsError(try env(["UITEST_HOOKS": "1"]))
        XCTAssertThrowsError(try env(["UITEST_HOOKS": "1", "UITEST_TOKEN": "short"]))
        XCTAssertNoThrow(try env(["UITEST_HOOKS": "1", "UITEST_TOKEN": goodToken]))
    }

    func testHooksRefusedInProduction() {
        XCTAssertThrowsError(try env(["UITEST_HOOKS": "1", "UITEST_TOKEN": goodToken,
                                      "NODE_ENV": "production", "JWT_SECRET": String(repeating: "s", count: 40)]))
    }

    // MARK: mounting

    private func mountedTestRoutes(_ e: AppEnv) async throws -> [String] {
        let app = try await Application.make(.testing)
        app.appEnv = e
        TestHooksController.register(routes: app.grouped("api"), app: app)
        let paths = app.routes.all.map { $0.path.map(\.description).joined(separator: "/") }
        try await app.asyncShutdown()
        return paths.filter { $0.hasPrefix("api/test") }
    }

    func testRoutesAbsentWhenOff() async throws {
        let paths = try await mountedTestRoutes(try env([:]))
        XCTAssertTrue(paths.isEmpty)
    }

    func testRoutesPresentWhenOn() async throws {
        let paths = try await mountedTestRoutes(try env(["UITEST_HOOKS": "1", "UITEST_TOKEN": goodToken]))
        XCTAssertEqual(Set(paths), ["api/test/users", "api/test/last-code", "api/test/runs/:runID", "api/test/runs/:runID/embed", "api/test/recruiters", "api/test/communities"])
    }

    // MARK: guard

    func testLoopbackOnly() {
        XCTAssertTrue(TestHooksController.Guard.isLoopback("127.0.0.1"))
        XCTAssertTrue(TestHooksController.Guard.isLoopback("::1"))
        XCTAssertFalse(TestHooksController.Guard.isLoopback("192.168.1.20"))
        XCTAssertFalse(TestHooksController.Guard.isLoopback("10.0.0.1"))
        XCTAssertFalse(TestHooksController.Guard.isLoopback(nil))
    }

    func testTokenMatch() {
        XCTAssertTrue(TestHooksController.Guard.tokensMatch(goodToken, goodToken))
        XCTAssertFalse(TestHooksController.Guard.tokensMatch(nil, goodToken))
        XCTAssertFalse(TestHooksController.Guard.tokensMatch("", goodToken))
        XCTAssertFalse(TestHooksController.Guard.tokensMatch(goodToken + "a", goodToken))
        XCTAssertFalse(TestHooksController.Guard.tokensMatch(String(repeating: "b", count: 32), goodToken))
        XCTAssertFalse(TestHooksController.Guard.tokensMatch("", ""))
    }

    // MARK: names

    func testRunIDFormat() {
        XCTAssertTrue(TestHooksController.isValidRunID("a1b2c3d4"))
        XCTAssertFalse(TestHooksController.isValidRunID("A1B2C3D4"))
        XCTAssertFalse(TestHooksController.isValidRunID("a1b2c3d"))
        XCTAssertFalse(TestHooksController.isValidRunID("a1b2c3d4e"))
        XCTAssertFalse(TestHooksController.isValidRunID("a1b2_3d4"))
        XCTAssertFalse(TestHooksController.isValidRunID("a1b2.*d4"))
    }

    /// The wipe safety net must catch every account the hooks make, and
    /// only those, and the names must pass the sign-up rules.
    func testUsernamesMatchWipePatternAndRules() throws {
        let wipe = try NSRegularExpression(pattern: SeedDemoCommand.uiTestUsernamePattern)
        func matches(_ s: String) -> Bool {
            wipe.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
        }
        for n in [1, 5, 42] {
            let name = TestHooksController.username(run: "a1b2c3d4", n: n)
            XCTAssertTrue(matches(name), name)
            XCTAssertTrue(UsernameRules.isValidFormat(name), name)
        }
        XCTAssertFalse(matches("qa_ui_phase0_1"))
        XCTAssertFalse(matches("kujira1307"))
        XCTAssertFalse(matches("qa_test_bugfix1"))
    }

    func testCodeSinkForgetsOnlyItsRun() {
        let sink = TestCodeSink()
        sink.record("111111", for: "QA_UI_aaaaaaaa_1@example.test")
        sink.record("222222", for: "qa_ui_bbbbbbbb_1@example.test")
        XCTAssertEqual(sink.last(for: "qa_ui_aaaaaaaa_1@example.test"), "111111")
        sink.forgetRun("aaaaaaaa")
        XCTAssertNil(sink.last(for: "qa_ui_aaaaaaaa_1@example.test"))
        XCTAssertEqual(sink.last(for: "qa_ui_bbbbbbbb_1@example.test"), "222222")
    }
}

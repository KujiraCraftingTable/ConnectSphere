import XCTVapor
@testable import App

final class AppTests: XCTestCase {
    func testEnvLoadDefaults() throws {
        let env = try AppEnv.load { key in
            [
                "DB_HOST": "localhost", "DB_PORT": "5432", "DB_NAME": "connectsphere",
                "DB_USER": "connectsphere_user", "DB_PASSWORD": "connectsphere_pass",
            ][key]
        }
        XCTAssertEqual(env.port, 3000)
        XCTAssertEqual(env.jwt.expiresIn, "90d")
        XCTAssertEqual(env.ollama.model, "qwen2.5:7b-instruct-q4_k_m")
        XCTAssertEqual(env.db.poolMax, 10)
        XCTAssertFalse(env.isProduction)
    }

    func testEnvMissingRequiredThrows() {
        XCTAssertThrowsError(try AppEnv.load { _ in nil })
    }

    func testEnvWeakJWTRejectedInProduction() {
        XCTAssertThrowsError(try AppEnv.load { key in
            [
                "DB_HOST": "h", "DB_PORT": "5432", "DB_NAME": "d", "DB_USER": "u", "DB_PASSWORD": "p",
                "NODE_ENV": "production", "JWT_SECRET": "dev_secret",
            ][key]
        })
    }
}

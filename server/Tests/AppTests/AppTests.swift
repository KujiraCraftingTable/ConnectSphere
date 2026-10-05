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

    // MARK: JWTHS256 — must stay wire-compatible with `jsonwebtoken`.

    func testJWTDurationParsing() {
        XCTAssertEqual(JWTHS256.seconds(from: "90d"), 90 * 86400)
        XCTAssertEqual(JWTHS256.seconds(from: "1h"), 3600)
        XCTAssertEqual(JWTHS256.seconds(from: "3600"), 3600)
        XCTAssertEqual(JWTHS256.seconds(from: "30m"), 1800)
        XCTAssertEqual(JWTHS256.seconds(from: "junk"), 90 * 86400)
    }

    func testJWTRoundTrip() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let token = JWTHS256.sign(sub: "abc-123", secret: "s3cr3t", expiresIn: "90d", now: now)
        let parts = token.split(separator: ".")
        XCTAssertEqual(parts.count, 3)
        // header is the canonical jsonwebtoken header
        XCTAssertEqual(JWTHS256.b64Decode(String(parts[0])).flatMap { String(data: $0, encoding: .utf8) },
                       #"{"alg":"HS256","typ":"JWT"}"#)
        let payload = try JWTHS256.verify(token, secret: "s3cr3t", now: now.addingTimeInterval(60))
        XCTAssertEqual(payload.sub, "abc-123")
        XCTAssertEqual(payload.iat, 1_700_000_000)
        XCTAssertEqual(payload.exp, 1_700_000_000 + 90 * 86400)
    }

    func testJWTRejectsTamperAndExpiry() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let token = JWTHS256.sign(sub: "u", secret: "right", expiresIn: "1h", now: now)
        XCTAssertThrowsError(try JWTHS256.verify(token, secret: "wrong", now: now))
        XCTAssertThrowsError(try JWTHS256.verify(token, secret: "right", now: now.addingTimeInterval(7200)))
    }

    /// Voice notes (.m4a) and iPhone photos (.heic) were rejected after the
    /// Node→Swift port because the whitelist matched Vapor's extension-derived
    /// MIME, which maps m4a to audio/mpeg.
    func testChatAttachmentWhitelist() {
        let kind = MessagesController.attachmentType(forFilename:)
        XCTAssertEqual(kind("upload.m4a")?.messageType, "voice")
        XCTAssertEqual(kind("upload.m4a")?.ext, ".m4a")
        XCTAssertEqual(kind("IMG_0001.HEIC")?.messageType, "image")
        XCTAssertEqual(kind("upload.jpeg")?.ext, ".jpg")
        XCTAssertEqual(kind("clip.mov")?.messageType, "video")
        for rejected in ["evil.exe", "x.svg", "page.html", "noextension", "archive.m4a.zip"] {
            XCTAssertNil(kind(rejected), rejected)
        }
    }
}

import Vapor
import SQLKit

/// Port of `backend/src/routes/uploadRoutes.js` — generic media upload, used
/// by post image attachments, avatar/cover-photo upload, and Stories. Was
/// never carried over in the initial Node→Swift port (`configure.swift` had
/// a stale "added in Phase 2" comment); its absence made all three features
/// silently fail, since `PostRepository.uploadImage` 404s and returns `nil`
/// rather than throwing.
struct UploadsController {
    /// `POST /api/uploads` — auth required, matches the Node route exactly.
    static func register(routes: any RoutesBuilder) {
        routes.grouped(AuthMiddleware())
            .on(.POST, "uploads", body: .collect(maxSize: "50mb"), use: create)
    }

    /// `GET /uploads/:filename` — public, no auth, mounted directly on `app`
    /// (bare path, no `/api` prefix — matches where `create`'s returned `url`
    /// actually points, and where `PostRepository.uploadImage` requests it
    /// from). Deliberately a single dynamic path segment, not a blanket
    /// `FileMiddleware` over all of `backend/uploads/`: that directory also
    /// holds `uploads/messages/` (private chat attachments) — a one-segment
    /// route structurally can't match that two-segment path, so this can't
    /// accidentally expose it. `registerMessageMedia` below is that subtree's
    /// own (auth-gated) route.
    static func registerPublic(_ app: Application) {
        app.get("uploads", ":filename", use: serve)
    }

    /// `GET /uploads/messages/:filename` — private chat attachments (photo/
    /// video/voice messages). Auth-gated, but can't reuse `AuthMiddleware`
    /// as-is: that only reads `Authorization: Bearer`, and `AsyncImage`/any
    /// plain GET-by-URL load (which is how this is always fetched — inline
    /// message media, not an explicit fetch call) can't attach custom
    /// headers. So the JWT rides along as `?token=`, exactly like
    /// `APIConfig.mediaURL` on the client already anticipates. Mirrors
    /// `AuthMiddleware`'s verify + soft-deleted-account rejection, just
    /// reading the token from the query string instead of the header.
    static func registerMessageMedia(_ app: Application) {
        app.get("uploads", "messages", ":filename", use: serveMessageMedia)
    }

    static func serveMessageMedia(_ req: Request) async throws -> Response {
        guard let token = req.query[String.self, at: "token"] else {
            throw Abort(.unauthorized, reason: "Missing token")
        }
        let secret = req.application.appEnv.jwt.secret
        guard let payload = try? JWTHS256.verify(token, secret: secret) else {
            throw Abort(.unauthorized, reason: "Invalid or expired token")
        }
        struct Row: Decodable { let deleted_at: Date? }
        let row = try? await req.db.sql()
            .raw("SELECT deleted_at FROM users WHERE id = \(uuid: payload.sub)")
            .first(decoding: Row.self)
        guard let row, row.deleted_at == nil else {
            throw Abort(.unauthorized, reason: "Invalid or expired token")
        }
        guard let filename = req.parameters.get("filename") else { throw Abort(.notFound) }
        let path = "\(MessagesController.uploadDir)/\(filename)"
        guard FileManager.default.fileExists(atPath: path) else { throw Abort(.notFound) }
        return req.fileio.streamFile(at: path)
    }

    struct UploadResponse: Content {
        var url: String
        var filename: String
        var type: String
        var size: Int
    }

    /// Extension is derived from the whitelisted MIME type, never trusted
    /// from the client's filename — same reasoning as the Node original:
    /// blocks uploading something like `.html`/`.svg` under a spoofed
    /// mimetype that would then get served back from `/uploads`.
    static let extByMime: [String: String] = [
        "image/jpeg": "jpg", "image/png": "png", "image/webp": "webp",
        "image/heic": "heic", "image/heif": "heif",
        "video/mp4": "mp4", "video/quicktime": "mov",
    ]
    static let uploadDir = "../backend/uploads"

    static func create(_ req: Request) async throws -> UploadResponse {
        struct FileBody: Content { var file: File }
        guard let file = try? req.content.decode(FileBody.self).file,
              let mime = file.contentType.map({ "\($0.type)/\($0.subType)" }),
              let ext = extByMime[mime] else {
            throw Abort(.badRequest, reason: "Invalid or missing file")
        }
        let name = "\(UUID().uuidString).\(ext)"
        try FileManager.default.createDirectory(atPath: uploadDir, withIntermediateDirectories: true)
        // GPS, camera and other identifying metadata never reach the disk.
        let cleaned = ByteBuffer(bytes: MetadataStripper.strip(Array(file.data.readableBytesView)))
        try await req.fileio.writeFile(cleaned, at: "\(uploadDir)/\(name)")
        let size = cleaned.readableBytes
        return UploadResponse(
            url: "/uploads/\(name)", filename: name,
            type: mime.hasPrefix("video/") ? "video" : "image",
            size: size)
    }

    static func serve(_ req: Request) async throws -> Response {
        guard let filename = req.parameters.get("filename") else { throw Abort(.notFound) }
        let path = "\(uploadDir)/\(filename)"
        guard FileManager.default.fileExists(atPath: path) else { throw Abort(.notFound) }
        return req.fileio.streamFile(at: path)
    }
}

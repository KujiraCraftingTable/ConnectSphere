import Vapor
import SQLKit

/// Generic media upload, used by post image attachments, avatar/cover-photo
/// upload, and Stories.
struct UploadsController {
    /// `POST /api/uploads`, auth required, matches the Node route exactly.
    static func register(routes: any RoutesBuilder) {
        routes.grouped(AuthMiddleware())
            .on(.POST, "uploads", body: .collect(maxSize: "50mb"), use: create)
    }

    /// `GET /uploads/:filename`, public, no auth, mounted directly on `app`
    /// (bare path, no `/api` prefix. Matches where `create`'s returned `url`
    /// actually points, and where `PostRepository.uploadImage` requests it
    /// from). Deliberately a single dynamic path segment, not a blanket
    /// `FileMiddleware` over all of `backend/uploads/`: that directory also
    /// holds `uploads/messages/` (private chat attachments). A one-segment
    /// route structurally can't match that two-segment path, so this can't
    /// accidentally expose it. `registerMessageMedia` below is that subtree's
    /// own (auth-gated) route.
    static func registerPublic(_ app: Application) {
        app.get("uploads", ":filename", use: serve)
    }

    /// `GET /uploads/messages/:filename`, private chat attachments (photo/
    /// video/voice messages). Auth-gated, but can't reuse `AuthMiddleware`
    /// as-is: that only reads `Authorization: Bearer`, and `AsyncImage`/any
    /// plain GET-by-URL load (which is how this is always fetched. Inline
    /// message media, not an explicit fetch call) can't attach custom
    /// headers. So the JWT rides along as `?token=`, exactly like
    /// `APIConfig.mediaURL` on the client already anticipates. Mirrors
    /// `AuthMiddleware`'s verify + dead-session rejection, just
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
        guard try await Session.isLive(payload, on: req.db.sql()) else {
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
    /// from the client's filename. Same reasoning as the Node original:
    /// blocks uploading something like `.html`/`.svg` under a spoofed
    /// mimetype that would then get served back from `/uploads`.
    static let extByMime: [String: String] = [
        "image/jpeg": "jpg", "image/png": "png", "image/webp": "webp",
        "image/heic": "heic", "image/heif": "heif",
        "video/mp4": "mp4", "video/quicktime": "mov",
    ]
    static let uploadDir = "../backend/uploads"

    /// A photo's feed-size copy (`<name>_t.jpg`), made on the phone. The
    /// server has no image library. Optional: older apps and videos send none.
    static let maxThumbnailBytes = 2 * 1024 * 1024

    static func create(_ req: Request) async throws -> UploadResponse {
        struct FileBody: Content { var file: File; var thumbnail: File? }
        let upload = try? req.content.decode(FileBody.self)
        guard let file = upload?.file,
              let mime = file.contentType.map({ "\($0.type)/\($0.subType)" }),
              let ext = extByMime[mime] else {
            throw Abort(.badRequest, reason: "Invalid or missing file")
        }
        let name = "\(UUID().uuidString).\(ext)"
        try FileManager.default.createDirectory(atPath: uploadDir, withIntermediateDirectories: true)
        // GPS, camera and other identifying metadata never reach the disk.
        let cleanedBytes = MetadataStripper.strip(Array(file.data.readableBytesView))
        let cleaned = ByteBuffer(bytes: cleanedBytes)
        // A photo a moderator removed for nudity, child safety or violence can't be sent again.
        let hash = MediaScan.sha256Hex(cleanedBytes)
        if try await MediaScan.isBanned(sha256: hash, on: req.db.sql()) {
            throw InlineError(.unprocessableEntity, "This file can't be uploaded.")
        }
        try await req.fileio.writeFile(cleaned, at: "\(uploadDir)/\(name)")
        if mime.hasPrefix("image/"), let thumb = upload?.thumbnail,
           thumb.contentType.map({ "\($0.type)/\($0.subType)" }) == "image/jpeg",
           thumb.data.readableBytes <= maxThumbnailBytes {
            let base = String(name.prefix(while: { $0 != "." }))
            let cleanThumb = ByteBuffer(bytes: MetadataStripper.strip(Array(thumb.data.readableBytesView)))
            try await req.fileio.writeFile(cleanThumb, at: "\(uploadDir)/\(base)_t.jpg")
        }
        let size = cleaned.readableBytes
        if mime.hasPrefix("image/") {
            await MediaScan.record(path: "/uploads/\(name)", sha256: hash, app: req.application,
                                   queue: BackgroundJobs.enabled ? req.queue : nil, logger: req.logger)
        }
        return UploadResponse(
            url: "/uploads/\(name)", filename: name,
            type: mime.hasPrefix("video/") ? "video" : "image",
            size: size)
    }

    static func serve(_ req: Request) async throws -> Response {
        guard let filename = req.parameters.get("filename"),
              let path = resolve(filename, exists: { FileManager.default.fileExists(atPath: "\(uploadDir)/\($0)") })
        else { throw Abort(.notFound) }
        let response = req.fileio.streamFile(at: "\(uploadDir)/\(path)")
        // Names are fresh UUIDs, so a file never changes under its URL.
        response.headers.replaceOrAdd(name: .cacheControl, value: "public, max-age=31536000, immutable")
        return response
    }

    /// The file to send for a requested name. A thumbnail (`<uuid>_t.jpg`)
    /// that was never made. An older upload, or a PNG kept for its
    /// transparency, falls back to its original.
    static func resolve(_ filename: String, exists: (String) -> Bool) -> String? {
        if exists(filename) { return filename }
        guard filename.hasSuffix("_t.jpg") else { return nil }
        let base = String(filename.dropLast("_t.jpg".count))
        return extByMime.values.sorted().map { "\(base).\($0)" }.first(where: exists)
    }
}

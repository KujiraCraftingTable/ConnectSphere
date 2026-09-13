import Vapor

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
    /// holds `uploads/messages/` (private chat attachments), which needs its
    /// own auth gate (still not built — see `configure.swift`) — a one-segment
    /// route structurally can't match a two-segment `messages/<file>` path, so
    /// this can't accidentally expose that subtree.
    static func registerPublic(_ app: Application) {
        app.get("uploads", ":filename", use: serve)
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
        let size = file.data.readableBytes
        try await req.fileio.writeFile(file.data, at: "\(uploadDir)/\(name)")
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

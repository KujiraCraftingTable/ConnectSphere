import Vapor
import SQLKit

/// Highlights on a Hobby profile: anyone's to view; your own to make, fill,
/// rename, re-cover and empty one photo at a time.
struct HighlightsController {
    static func register(routes: any RoutesBuilder) {
        let u = routes.grouped("users").grouped(AuthMiddleware())
        u.get(":id", "highlights", use: list)
        u.post("me", "highlights", use: create)
        u.patch("me", "highlights", ":highlightId", use: update)
        u.delete("me", "highlights", ":highlightId", use: remove)
        u.post("me", "highlights", ":highlightId", "items", use: addItems)
        u.delete("me", "highlights", ":highlightId", "items", ":itemId", use: removeItem)
    }

    /// Photos for a highlight: our own uploads (never chat media or CVs),
    /// or the images of your own Hobby stories.
    struct PhotosBody: Content {
        var title: String?
        var image_urls: [String]?
        var story_ids: [String]?
    }

    static func cleanTitle(_ raw: String?) throws -> String {
        let title = (raw ?? "").trimmedText
        guard (1...30).contains(title.count) else { throw Abort(.badRequest, reason: "The title must be 1 to 30 characters") }
        return title
    }

    private static func photos(_ b: PhotosBody, user: String, on db: any SQLDatabase) async throws -> [String] {
        var images: [String] = []
        for raw in b.image_urls ?? [] {
            guard let path = MediaPath.storable(raw), MediaPath.isPublicUpload(path), MediaPath.ownFileExists(path) else {
                throw Abort(.badRequest, reason: "Invalid photo")
            }
            images.append(path)
        }
        for id in b.story_ids ?? [] {
            guard UUID(uuidString: id) != nil, let image = try await HighlightStore.storyImage(id, of: user, on: db) else {
                throw Abort(.badRequest, reason: "Story not found")
            }
            images.append(image)
        }
        guard !images.isEmpty else { throw Abort(.badRequest, reason: "Add at least one photo") }
        return images
    }

    static func list(_ req: Request) async throws -> DataListResponse<HighlightStore.Highlight> {
        var id = req.parameters.get("id")!
        if id == "me" { id = req.userID }
        guard UUID(uuidString: id) != nil else { throw Abort(.notFound) }
        if try await ProfileLock.lockedOut(viewer: req.userID, owner: id, mode: "hobby", on: req.db.sql()) {
            return DataListResponse(data: [])
        }
        return DataListResponse(data: try await HighlightStore.list(of: id.lowercased(), on: req.db.sql()))
    }

    static func create(_ req: Request) async throws -> DataListResponse<HighlightStore.Highlight> {
        let b = try req.content.decode(PhotosBody.self)
        let title = try cleanTitle(b.title)
        let db = req.db.sql()
        let images = try await photos(b, user: req.userID, on: db)
        guard images.count <= HighlightStore.maxItems else {
            throw Abort(.badRequest, reason: "A highlight holds up to \(HighlightStore.maxItems) photos")
        }
        guard try await HighlightStore.count(of: req.userID, on: db) < HighlightStore.maxHighlights else {
            throw Abort(.badRequest, reason: "You can have up to \(HighlightStore.maxHighlights) highlights")
        }
        try await HighlightStore.create(req.userID, title: title, images: images, on: req.db)
        return DataListResponse(data: try await HighlightStore.list(of: req.userID, on: db))
    }

    static func addItems(_ req: Request) async throws -> DataListResponse<HighlightStore.Highlight> {
        guard let hid = req.parameters.get("highlightId"), UUID(uuidString: hid) != nil else { throw Abort(.notFound) }
        let db = req.db.sql()
        guard let have = try await HighlightStore.itemCount(hid, of: req.userID, on: db) else { throw Abort(.notFound) }
        let images = try await photos(try req.content.decode(PhotosBody.self), user: req.userID, on: db)
        guard have + images.count <= HighlightStore.maxItems else {
            throw Abort(.badRequest, reason: "A highlight holds up to \(HighlightStore.maxItems) photos")
        }
        try await HighlightStore.addItems(hid, images: images, on: db)
        return DataListResponse(data: try await HighlightStore.list(of: req.userID, on: db))
    }

    struct UpdateBody: Content { var title: String?; var cover_url: String? }

    static func update(_ req: Request) async throws -> DataListResponse<HighlightStore.Highlight> {
        guard let hid = req.parameters.get("highlightId"), UUID(uuidString: hid) != nil else { throw Abort(.notFound) }
        let b = try req.content.decode(UpdateBody.self)
        let title = try b.title.map { try cleanTitle($0) }
        var cover: String?? = nil
        if let raw = b.cover_url {
            guard let path = MediaPath.storable(raw), MediaPath.isPublicUpload(path), MediaPath.ownFileExists(path) else {
                throw Abort(.badRequest, reason: "Invalid photo")
            }
            cover = .some(path)
        }
        let db = req.db.sql()
        guard try await HighlightStore.update(hid, of: req.userID, title: title, coverURL: cover, on: db) else {
            throw Abort(.notFound)
        }
        return DataListResponse(data: try await HighlightStore.list(of: req.userID, on: db))
    }

    static func removeItem(_ req: Request) async throws -> DataListResponse<HighlightStore.Highlight> {
        guard let hid = req.parameters.get("highlightId"), UUID(uuidString: hid) != nil,
              let iid = req.parameters.get("itemId"), UUID(uuidString: iid) != nil else { throw Abort(.notFound) }
        guard try await HighlightStore.removeItem(iid, from: hid, of: req.userID, on: req.db) else { throw Abort(.notFound) }
        return DataListResponse(data: try await HighlightStore.list(of: req.userID, on: req.db.sql()))
    }

    static func remove(_ req: Request) async throws -> DataListResponse<HighlightStore.Highlight> {
        guard let hid = req.parameters.get("highlightId"), UUID(uuidString: hid) != nil else { throw Abort(.notFound) }
        let db = req.db.sql()
        guard try await HighlightStore.delete(hid, of: req.userID, on: db) else { throw Abort(.notFound) }
        return DataListResponse(data: try await HighlightStore.list(of: req.userID, on: db))
    }
}

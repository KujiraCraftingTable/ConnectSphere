import Vapor
import SQLKit

/// Education on a Hobby profile: anyone's to read; your own to add, edit and remove.
struct EducationsController {
    static func register(routes: any RoutesBuilder) {
        let u = routes.grouped("users").grouped(AuthMiddleware())
        u.get(":id", "educations", use: list)
        u.post("me", "educations", use: create)
        u.patch("me", "educations", ":educationId", use: update)
        u.delete("me", "educations", ":educationId", use: remove)
    }

    struct Body: Content {
        var school_name: String?
        var school_type: String?
        var major: String?
        var start_year: Int?
        var end_year: Int?
    }

    /// Trims and checks one school. Years 1950 … a few years ahead (people
    /// list where they'll graduate); the end can't come before the start.
    static func validate(_ b: Body, now: Date = Date()) throws -> EducationStore.Fields {
        let name = (b.school_name ?? "").trimmedText
        guard (2...150).contains(name.count) else { throw Abort(.badRequest, reason: "School must be 2 to 150 characters") }
        guard let type = b.school_type, EducationStore.schoolTypes.contains(type) else {
            throw Abort(.badRequest, reason: "Invalid school type")
        }
        let major = b.major?.trimmedText.nilIfEmpty
        if let major, major.count > 100 { throw Abort(.badRequest, reason: "Major must be at most 100 characters") }
        let thisYear = Calendar(identifier: .gregorian).component(.year, from: now)
        let years = 1950...(thisYear + 7)
        for y in [b.start_year, b.end_year].compactMap({ $0 }) where !years.contains(y) {
            throw Abort(.badRequest, reason: "Years must be between 1950 and \(thisYear + 7)")
        }
        if let s = b.start_year, let e = b.end_year, e < s {
            throw Abort(.badRequest, reason: "The end can't be before the start")
        }
        return .init(schoolName: name, schoolType: type, major: major, startYear: b.start_year, endYear: b.end_year)
    }

    static func list(_ req: Request) async throws -> DataListResponse<EducationStore.Education> {
        var id = req.parameters.get("id")!
        if id == "me" { id = req.userID }
        guard UUID(uuidString: id) != nil else { throw Abort(.notFound) }
        if try await ProfileLock.lockedOut(viewer: req.userID, owner: id, mode: "hobby", on: req.db.sql()) {
            return DataListResponse(data: [])
        }
        return DataListResponse(data: try await EducationStore.list(of: id.lowercased(), on: req.db.sql()))
    }

    static func create(_ req: Request) async throws -> DataListResponse<EducationStore.Education> {
        let fields = try validate(try req.content.decode(Body.self))
        let db = req.db.sql()
        guard try await EducationStore.count(of: req.userID, on: db) < EducationStore.maxEntries else {
            throw Abort(.badRequest, reason: "You can list up to \(EducationStore.maxEntries) schools")
        }
        try await EducationStore.create(req.userID, fields, on: db)
        await BackgroundJobs.refreshEmbedding(req, .profile, id: req.userID)
        return DataListResponse(data: try await EducationStore.list(of: req.userID, on: db))
    }

    static func update(_ req: Request) async throws -> DataListResponse<EducationStore.Education> {
        guard let id = req.parameters.get("educationId"), UUID(uuidString: id) != nil else { throw Abort(.notFound) }
        let fields = try validate(try req.content.decode(Body.self))
        let db = req.db.sql()
        guard try await EducationStore.update(id, of: req.userID, fields, on: db) else { throw Abort(.notFound) }
        await BackgroundJobs.refreshEmbedding(req, .profile, id: req.userID)
        return DataListResponse(data: try await EducationStore.list(of: req.userID, on: db))
    }

    static func remove(_ req: Request) async throws -> DataListResponse<EducationStore.Education> {
        guard let id = req.parameters.get("educationId"), UUID(uuidString: id) != nil else { throw Abort(.notFound) }
        let db = req.db.sql()
        guard try await EducationStore.remove(id, of: req.userID, on: db) else { throw Abort(.notFound) }
        return DataListResponse(data: try await EducationStore.list(of: req.userID, on: db))
    }
}

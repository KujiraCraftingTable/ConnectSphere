import Vapor
import SQLKit

/// Work history: anyone's roles to read; your own to add, edit and remove.
struct ExperiencesController {
    static func register(routes: any RoutesBuilder) {
        let u = routes.grouped("users").grouped(AuthMiddleware())
        u.get(":id", "experiences", use: list)
        u.post("me", "experiences", use: create)
        u.patch("me", "experiences", ":experienceId", use: update)
        u.delete("me", "experiences", ":experienceId", use: remove)
        routes.grouped("companies").grouped(AuthMiddleware()).get(":id", "people", use: people)
    }

    struct Body: Content {
        var company_id: String?
        var company_name: String?
        var title: String?
        var employment_type: String?
        var location: String?
        var location_type: String?
        /// "YYYY-MM".
        var start_month: String?
        /// "YYYY-MM", or null for the current role.
        var end_month: String?
        var description: String?
    }

    /// "2024-03" → 1 March 2024 (UTC); nil if it isn't a real month.
    static func month(_ s: String?) -> Date? {
        guard let s, s.count == 7, s[s.index(s.startIndex, offsetBy: 4)] == "-",
              let y = Int(s.prefix(4)), let m = Int(s.suffix(2)), (1900...2200).contains(y), (1...12).contains(m)
        else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: DateComponents(year: y, month: m, day: 1))
    }

    /// Trims and checks a role. The company comes from its page when linked;
    /// otherwise its typed name. Months can't be in the future and the end
    /// can't come before the start.
    static func validate(_ b: Body, companyName pageName: String?, now: Date = Date()) throws -> ExperienceStore.Fields {
        let title = (b.title ?? "").trimmedText
        guard (1...100).contains(title.count) else { throw Abort(.badRequest, reason: "Title must be 1 to 100 characters") }
        let company = pageName ?? (b.company_name ?? "").trimmedText
        guard (1...100).contains(company.count) else { throw Abort(.badRequest, reason: "Company must be 1 to 100 characters") }
        guard let type = b.employment_type, ExperienceStore.employmentTypes.contains(type) else {
            throw Abort(.badRequest, reason: "Invalid employment type")
        }
        if let lt = b.location_type, !lt.isEmpty, !ExperienceStore.locationTypes.contains(lt) {
            throw Abort(.badRequest, reason: "Invalid location type")
        }
        guard let start = month(b.start_month) else { throw Abort(.badRequest, reason: "Start month must be YYYY-MM") }
        var end: Date? = nil
        if let e = b.end_month, !e.isEmpty {
            guard let parsed = month(e) else { throw Abort(.badRequest, reason: "End month must be YYYY-MM") }
            end = parsed
        }
        guard start <= now, (end ?? start) <= now else { throw Abort(.badRequest, reason: "Dates can't be in the future") }
        if let end, end < start { throw Abort(.badRequest, reason: "The end can't be before the start") }
        let location = b.location?.trimmedText.nilIfEmpty
        if let l = location, l.count > 100 { throw Abort(.badRequest, reason: "Location must be at most 100 characters") }
        let description = b.description?.trimmedText.nilIfEmpty
        if let d = description, d.count > 2000 { throw Abort(.badRequest, reason: "Description must be at most 2000 characters") }
        return ExperienceStore.Fields(
            companyID: pageName == nil ? nil : b.company_id?.lowercased(), companyName: company, title: title,
            employmentType: type, location: location, locationType: b.location_type?.nilIfEmpty,
            start: start, end: end, description: description)
    }

    /// The linked page's name, or nil when the role isn't linked (404 if the
    /// page doesn't exist).
    private static func pageName(_ b: Body, on db: any SQLDatabase) async throws -> String? {
        guard let id = b.company_id?.nilIfEmpty else { return nil }
        guard UUID(uuidString: id) != nil else { throw Abort(.badRequest, reason: "Invalid company") }
        struct R: Decodable { let name: String }
        guard let row = try await db.raw("SELECT name FROM companies WHERE id = \(uuid: id)").first(decoding: R.self) else {
            throw Abort(.notFound, reason: "Company not found")
        }
        return row.name
    }

    static func list(_ req: Request) async throws -> DataListResponse<ExperienceStore.Experience> {
        var id = req.parameters.get("id")!
        if id == "me" { id = req.userID }
        guard UUID(uuidString: id) != nil else { throw Abort(.notFound) }
        return DataListResponse(data: try await ExperienceStore.list(of: id, on: req.db.sql()))
    }

    static func create(_ req: Request) async throws -> Response {
        let db = req.db.sql()
        let b = try req.content.decode(Body.self)
        let fields = try validate(b, companyName: try await pageName(b, on: db))
        guard try await ExperienceStore.count(of: req.userID, on: db) < ExperienceStore.maxPerUser else {
            throw Abort(.badRequest, reason: "You can list up to \(ExperienceStore.maxPerUser) roles")
        }
        _ = try await ExperienceStore.create(fields, user: req.userID, on: db)
        return try await ConnectionsController.encode(try await afterChange(req), req, .created)
    }

    static func update(_ req: Request) async throws -> DataListResponse<ExperienceStore.Experience> {
        let db = req.db.sql()
        let b = try req.content.decode(Body.self)
        let fields = try validate(b, companyName: try await pageName(b, on: db))
        guard let eid = req.parameters.get("experienceId"), UUID(uuidString: eid) != nil,
              try await ExperienceStore.update(eid, fields, user: req.userID, on: db) else {
            throw Abort(.notFound, reason: "Role not found")
        }
        return try await afterChange(req)
    }

    static func remove(_ req: Request) async throws -> DataListResponse<ExperienceStore.Experience> {
        guard let eid = req.parameters.get("experienceId"), UUID(uuidString: eid) != nil,
              try await ExperienceStore.remove(eid, user: req.userID, on: req.db.sql()) else {
            throw Abort(.notFound, reason: "Role not found")
        }
        return try await afterChange(req)
    }

    /// Keeps the profile's job title / company in step, refreshes its
    /// embedding, and answers with the whole updated list.
    private static func afterChange(_ req: Request) async throws -> DataListResponse<ExperienceStore.Experience> {
        let db = req.db.sql()
        try await ExperienceStore.syncCurrentRole(of: req.userID, on: db)
        await BackgroundJobs.refreshEmbedding(req, .profile, id: req.userID)
        return DataListResponse(data: try await ExperienceStore.list(of: req.userID, on: db))
    }

    static func people(_ req: Request) async throws -> DataListResponse<ExperienceStore.Person> {
        guard let id = req.parameters.get("id"), UUID(uuidString: id) != nil else { throw Abort(.notFound) }
        let limit = PostsController.clamp(try? req.query.get(Int.self, at: "limit"), 50, 1, 100)
        return DataListResponse(data: try await ExperienceStore.currentPeople(at: id, limit: limit, on: req.db.sql()))
    }
}

import Vapor
import SQLKit

/// Company pages (Work mode): create, view, edit (admins), search, follow.
/// Anyone can create a page and runs it as its owner; "Official" comes only
/// from the app admin (`swift run App verify-company <slug>`).
struct CompaniesController {
    static func register(routes: any RoutesBuilder) {
        let c = routes.grouped("companies").grouped(AuthMiddleware())
        c.get(use: search)
        c.post(use: create)
        c.get("mine", use: mine)
        c.get(":id", use: get)
        c.patch(":id", use: update)
        c.post(":id", "follow", use: follow)
        c.delete(":id", "follow", use: unfollow)
    }

    struct Body: Content {
        var name: String?
        var logo_url: String?
        var cover_url: String?
        var about: String?
        var industry: String?
        var size: String?
        var website: String?
        var headquarters: String?
        var founded_year: Int?
    }

    /// Trims and checks the fields; blank optional fields become nil.
    static func validate(_ b: Body, now: Date = Date()) throws -> CompanyStore.Fields {
        try ModerationGate.check([b.name, b.industry, b.website], .name)
        try ModerationGate.check([b.about], .text)
        let name = (b.name ?? "").trimmedText
        guard (2...100).contains(name.count) else {
            throw Abort(.badRequest, reason: "Company name must be 2 to 100 characters")
        }
        func text(_ s: String?, max: Int, _ label: String) throws -> String? {
            guard let t = s?.trimmedText.nilIfEmpty else { return nil }
            guard t.count <= max else { throw Abort(.badRequest, reason: "\(label) must be at most \(max) characters") }
            return t
        }
        var website = try text(b.website, max: 200, "Website")
        if let w = website {
            // "fpt.com" is fine; it's stored as https://fpt.com.
            let full = w.lowercased().hasPrefix("http://") || w.lowercased().hasPrefix("https://") ? w : "https://" + w
            guard let url = URL(string: full), let host = url.host, host.contains("."), !host.hasPrefix(".") else {
                throw Abort(.badRequest, reason: "Website must be a web address")
            }
            website = full
        }
        if let s = b.size, !s.isEmpty, !CompanyStore.sizes.contains(s) {
            throw Abort(.badRequest, reason: "Invalid company size")
        }
        let year = Calendar(identifier: .gregorian).component(.year, from: now)
        if let y = b.founded_year, !(1800...year).contains(y) {
            throw Abort(.badRequest, reason: "Founded year must be between 1800 and \(year)")
        }
        // Only our own uploads: a page's images can't point at another site.
        func image(_ raw: String?) throws -> String? {
            guard let stored = MediaPath.storable(raw) else { return nil }
            guard stored.hasPrefix("/uploads/"), !stored.contains("..") else {
                throw Abort(.badRequest, reason: "Images must be uploaded")
            }
            return stored
        }
        return CompanyStore.Fields(
            name: name, logoURL: try image(b.logo_url), coverURL: try image(b.cover_url),
            about: try text(b.about, max: 2000, "About"), industry: try text(b.industry, max: 80, "Industry"),
            size: b.size?.nilIfEmpty, website: website, headquarters: try text(b.headquarters, max: 100, "Headquarters"),
            foundedYear: b.founded_year)
    }

    static func search(_ req: Request) async throws -> DataListResponse<CompanyStore.Company> {
        let q = ((try? req.query.get(String.self, at: "q")) ?? "").trimmedText
        let limit = PostsController.clamp(try? req.query.get(Int.self, at: "limit"), 20, 1, 50)
        guard q.count <= 100 else { throw Abort(.badRequest, reason: "Search is too long") }
        return DataListResponse(data: try await CompanyStore.search(q, viewer: req.userID, limit: limit, on: req.db.sql()))
    }

    static func mine(_ req: Request) async throws -> DataListResponse<CompanyStore.Company> {
        DataListResponse(data: try await CompanyStore.administered(by: req.userID, on: req.db.sql()))
    }

    static func get(_ req: Request) async throws -> DataResponse<CompanyStore.Company> {
        DataResponse(data: try await company(req))
    }

    static func create(_ req: Request) async throws -> Response {
        let fields = try validate(try req.content.decode(Body.self))
        let db = req.db.sql()
        guard try await !CompanyStore.nameTaken(fields.name, on: db) else {
            throw Abort(.conflict, reason: "A page for this company already exists")
        }
        let id = try await CompanyStore.create(fields, owner: req.userID, on: req.db)
        await ModerationScan.enqueue(req, .company, id: id)
        guard let made = try await CompanyStore.byID(id, viewer: req.userID, on: db) else { throw Abort(.internalServerError) }
        return try await ConnectionsController.encode(DataResponse(data: made), req, .created)
    }

    static func update(_ req: Request) async throws -> DataResponse<CompanyStore.Company> {
        let id = try companyID(req)
        let db = req.db.sql()
        guard try await CompanyStore.role(of: req.userID, in: id, on: db) != nil else {
            throw Abort(.forbidden, reason: "Only the page's admins can edit it")
        }
        let fields = try validate(try req.content.decode(Body.self))
        guard try await !CompanyStore.nameTaken(fields.name, except: id, on: db) else {
            throw Abort(.conflict, reason: "A page for this company already exists")
        }
        try await CompanyStore.update(id, fields, on: db)
        await ModerationScan.enqueue(req, .company, id: id)
        return DataResponse(data: try await company(req))
    }

    static func follow(_ req: Request) async throws -> DataResponse<CompanyStore.Company> {
        _ = try await company(req)
        try await CompanyStore.setFollowing(true, company: try companyID(req), user: req.userID, on: req.db)
        return DataResponse(data: try await company(req))
    }

    static func unfollow(_ req: Request) async throws -> DataResponse<CompanyStore.Company> {
        _ = try await company(req)
        try await CompanyStore.setFollowing(false, company: try companyID(req), user: req.userID, on: req.db)
        return DataResponse(data: try await company(req))
    }

    private static func companyID(_ req: Request) throws -> String {
        guard let id = req.parameters.get("id"), UUID(uuidString: id) != nil else {
            throw Abort(.notFound, reason: "Company not found")
        }
        return id
    }

    private static func company(_ req: Request) async throws -> CompanyStore.Company {
        guard let c = try await CompanyStore.byID(try companyID(req), viewer: req.userID, on: req.db.sql()) else {
            throw Abort(.notFound, reason: "Company not found")
        }
        return c
    }
}

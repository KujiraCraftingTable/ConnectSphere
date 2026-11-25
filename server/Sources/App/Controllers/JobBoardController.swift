import Vapor
import SQLKit

/// The Jobs tab: recommended, search with filters, saved, one job, a company's jobs.
struct JobBoardController {
    static func register(routes: any RoutesBuilder) {
        let j = routes.grouped("jobs").grouped(AuthMiddleware())
        j.get(use: search)
        j.get("recommended", use: recommended)
        j.get("saved", use: saved)
        // Your own open jobs, e.g. to offer one on an "Open to work" post.
        j.get("mine", use: mine)
        j.get(":id", use: get)
        routes.grouped("companies").grouped(AuthMiddleware()).get(":id", "jobs", use: companyJobs)
    }

    // MARK: - Filters
    private static let employmentTypes: Set<String> = ["full_time", "part_time", "contract", "internship", "remote"]

    /// Query filters, each checked against its allowlist.
    static func filters(_ req: Request) throws -> JobBoardStore.Filters {
        var f = JobBoardStore.Filters()
        f.q = (try? req.query.get(String.self, at: "q"))?.trimmedText
        f.location = (try? req.query.get(String.self, at: "location"))?.trimmedText
        if let q = f.q, q.count > 100 { throw Abort(.badRequest, reason: "Search is too long") }
        if let l = f.location, l.count > 100 { throw Abort(.badRequest, reason: "Location is too long") }
        if let t = (try? req.query.get(String.self, at: "type"))?.nilIfEmpty {
            guard employmentTypes.contains(t) else { throw Abort(.badRequest, reason: "Invalid job type") }
            f.employmentType = t
        }
        if let w = (try? req.query.get(String.self, at: "format"))?.nilIfEmpty {
            guard JobStore.workFormats.contains(w) else { throw Abort(.badRequest, reason: "Invalid work format") }
            f.workFormat = w
        }
        if let lv = (try? req.query.get(String.self, at: "level"))?.nilIfEmpty {
            guard JobStore.levels.contains(lv) else { throw Abort(.badRequest, reason: "Invalid level") }
            f.level = lv
        }
        if let r = try? req.query.get(Double.self, at: "radius_km") {
            guard SearchStore.radiusStepsKm.contains(r) else { throw Abort(.badRequest, reason: "Invalid distance") }
            f.radiusKm = r
        }
        if let s = try? req.query.get(Int.self, at: "salary_min") {
            guard (0...100_000).contains(s) else { throw Abort(.badRequest, reason: "Invalid salary") }
            f.salaryMin = s
        }
        f.limit = PostsController.clamp(try? req.query.get(Int.self, at: "limit"), 30, 1, 50)
        f.offset = req.pageOffset
        return f
    }

    // MARK: - Listings
    static func search(_ req: Request) async throws -> DataListResponse<JobBoardStore.Listing> {
        DataListResponse(data: try await JobBoardStore.search(try filters(req), viewer: req.userID, on: req.db.sql()))
    }

    static func mine(_ req: Request) async throws -> DataListResponse<JobBoardStore.Listing> {
        var f = JobBoardStore.Filters()
        f.authorID = req.userID
        f.limit = 50
        return DataListResponse(data: try await JobBoardStore.search(f, viewer: req.userID, on: req.db.sql()))
    }

    static func saved(_ req: Request) async throws -> DataListResponse<JobBoardStore.Listing> {
        var f = try filters(req)
        f.savedOnly = true
        return DataListResponse(data: try await JobBoardStore.search(f, viewer: req.userID, on: req.db.sql()))
    }

    static func recommended(_ req: Request) async throws -> DataListResponse<JobBoardStore.Listing> {
        let limit = PostsController.clamp(try? req.query.get(Int.self, at: "limit"), 30, 1, 50)
        return DataListResponse(data: try await JobBoardStore.recommended(viewer: req.userID, limit: limit, on: req.db.sql()))
    }

    static func get(_ req: Request) async throws -> DataResponse<JobBoardStore.Listing> {
        guard let id = req.parameters.get("id"), UUID(uuidString: id) != nil,
              let job = try await JobBoardStore.byID(id, viewer: req.userID, on: req.db.sql()) else {
            throw Abort(.notFound, reason: "Job not found")
        }
        return DataResponse(data: job)
    }

    static func companyJobs(_ req: Request) async throws -> DataListResponse<JobBoardStore.Listing> {
        guard let id = req.parameters.get("id"), UUID(uuidString: id) != nil else { throw Abort(.notFound) }
        var f = JobBoardStore.Filters()
        f.companyID = id
        f.limit = 50
        return DataListResponse(data: try await JobBoardStore.search(f, viewer: req.userID, on: req.db.sql()))
    }
}

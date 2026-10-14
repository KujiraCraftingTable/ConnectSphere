import Vapor
import SQLKit

/// Easy Apply: apply with your profile (+ note, + CV), follow your
/// applications, and — for a job's poster or company admins — its applicants.
struct ApplicationsController {
    static func register(routes: any RoutesBuilder, app: Application) {
        let j = routes.grouped("jobs").grouped(AuthMiddleware())
        j.post(":id", "apply", use: apply)
        j.get(":id", "applications", use: applicants)
        j.get("applications", "mine", use: mine)
        j.patch("applications", ":applicationId", use: setStatus)
        j.on(.POST, "cv", body: .collect(maxSize: "10mb"), use: uploadCV)
        // CVs are private: only their owner and the managers of a job they
        // were sent to can open one (token in the query, like chat media).
        app.get("uploads", "cv", ":filename", use: serveCV)
    }

    static let cvDir = UploadsController.uploadDir + "/cv"

    struct ApplyBody: Content { var note: String?; var cv_url: String? }

    static func apply(_ req: Request) async throws -> Response {
        guard let jobID = req.parameters.get("id"), UUID(uuidString: jobID) != nil else { throw Abort(.notFound) }
        let db = req.db.sql()
        let me = req.userID.lowercased()
        guard let job = try await JobBoardStore.byID(jobID, viewer: me, on: db) else {
            throw Abort(.notFound, reason: "This job isn't open")
        }
        guard !job.is_mine else { throw Abort(.forbidden, reason: "You can't apply to your own job") }
        struct P: Decodable { let ok: Bool }
        guard try await db.raw("SELECT (work_display_name IS NOT NULL) AS ok FROM users WHERE id = \(uuid: me)")
            .first(decoding: P.self)?.ok == true else {
            throw Abort(.badRequest, reason: "Set up your Work profile before applying")
        }
        let b = try req.content.decode(ApplyBody.self)
        let note = b.note?.trimmedText.nilIfEmpty
        if let note, note.count > ApplicationStore.maxNoteLength {
            throw Abort(.badRequest, reason: "The note must be at most \(ApplicationStore.maxNoteLength) characters")
        }
        var cv: String?
        if let raw = b.cv_url?.nilIfEmpty {
            // Only a CV this person uploaded.
            let name = String(raw.dropFirst("/uploads/cv/".count))
            guard raw.hasPrefix("/uploads/cv/"), name.hasPrefix(me + "_"), !name.contains("/"), !name.contains(".."),
                  FileManager.default.fileExists(atPath: "\(cvDir)/\(name)") else {
                throw Abort(.badRequest, reason: "Invalid CV")
            }
            cv = raw
        }
        guard let appID = try await ApplicationStore.apply(job: jobID, applicant: me, note: note, cvURL: cv, on: req.db) else {
            throw Abort(.conflict, reason: "You've already applied to this job")
        }
        let managers = try await ApplicationStore.managers(of: jobID, on: db).filter { $0.lowercased() != me }
        let title = job.title
        NotifyService.fireAndForget(req) { d, h, l in
            var payload = (try? await NotifyService.actorPayload(me, on: d)) ?? ["fromUserId": me]
            payload["jobId"] = jobID
            payload["jobTitle"] = title
            payload["mode"] = "work"
            for m in managers {
                _ = await NotifyService.pushUserNotification(
                    userID: m, type: "job_application", actorID: me, entityType: "job", entityID: jobID,
                    payload: payload, on: d, hub: h, logger: l)
            }
        }
        guard let made = try await ApplicationStore.byID(appID, on: db) else { throw Abort(.internalServerError) }
        return try await ConnectionsController.encode(DataResponse(data: made), req, .created)
    }

    static func mine(_ req: Request) async throws -> DataListResponse<ApplicationStore.Application> {
        DataListResponse(data: try await ApplicationStore.mine(req.userID, on: req.db.sql()))
    }

    static func applicants(_ req: Request) async throws -> DataListResponse<ApplicationStore.Application> {
        guard let jobID = req.parameters.get("id"), UUID(uuidString: jobID) != nil else { throw Abort(.notFound) }
        let db = req.db.sql()
        guard try await ApplicationStore.canManage(job: jobID, user: req.userID, on: db) else {
            throw Abort(.forbidden, reason: "Only the job's poster or company admins can see applicants")
        }
        return DataListResponse(data: try await ApplicationStore.forJob(jobID, on: db))
    }

    struct StatusBody: Content { var status: String? }

    /// The poster or company admins move an application along; the
    /// applicant is told (opening it marks it "viewed" quietly).
    static func setStatus(_ req: Request) async throws -> DataResponse<ApplicationStore.Application> {
        guard let id = req.parameters.get("applicationId"), UUID(uuidString: id) != nil else { throw Abort(.notFound) }
        guard let status = try req.content.decode(StatusBody.self).status, ApplicationStore.managerStatuses.contains(status) else {
            throw Abort(.badRequest, reason: "Invalid status")
        }
        let db = req.db.sql()
        guard let application = try await ApplicationStore.byID(id, on: db),
              try await ApplicationStore.canManage(job: application.job_id, user: req.userID, on: db) else {
            throw Abort(.notFound, reason: "Application not found")
        }
        // "Viewed" never takes an application back from a later step.
        if status == "viewed" && application.status != "applied" {
            var unchanged = application
            unchanged.match = try await JobBoardStore.byID(application.job_id, viewer: application.applicant.id, on: db)?.match
            return DataResponse(data: unchanged)
        }
        let changed = try await ApplicationStore.setStatus(id, to: status, on: req.db)
        if changed && status != "viewed" {
            let actor = req.userID, applicant = application.applicant.id
            let jobID = application.job_id, title = application.job_title
            NotifyService.fireAndForget(req) { d, h, l in
                var payload = (try? await NotifyService.actorPayload(actor, on: d)) ?? ["fromUserId": actor]
                payload["jobId"] = jobID
                payload["jobTitle"] = title
                payload["status"] = status
                payload["mode"] = "work"
                _ = await NotifyService.pushUserNotification(
                    userID: applicant, type: "application_status", actorID: actor, entityType: "job", entityID: jobID,
                    payload: payload, on: d, hub: h, logger: l)
            }
        }
        guard var updated = try await ApplicationStore.byID(id, on: db) else { throw Abort(.internalServerError) }
        // Same shape as the applicants list, so the app can swap it in.
        updated.match = try await JobBoardStore.byID(updated.job_id, viewer: updated.applicant.id, on: db)?.match
        return DataResponse(data: updated)
    }

    struct CVResponse: Content { var url: String }

    /// A PDF CV, at most 10 MB, saved under the uploader's id.
    static func uploadCV(_ req: Request) async throws -> CVResponse {
        struct FileBody: Content { var file: File }
        guard let file = try? req.content.decode(FileBody.self).file else { throw Abort(.badRequest, reason: "Missing file") }
        let bytes = Array(file.data.readableBytesView)
        guard bytes.starts(with: Array("%PDF".utf8)) else { throw Abort(.badRequest, reason: "The CV must be a PDF") }
        let name = "\(req.userID.lowercased())_\(UUID().uuidString.lowercased()).pdf"
        try FileManager.default.createDirectory(atPath: cvDir, withIntermediateDirectories: true)
        try await req.fileio.writeFile(ByteBuffer(bytes: bytes), at: "\(cvDir)/\(name)")
        return CVResponse(url: "/uploads/cv/\(name)")
    }

    static func serveCV(_ req: Request) async throws -> Response {
        guard let token = req.query[String.self, at: "token"],
              let payload = try? JWTHS256.verify(token, secret: req.application.appEnv.jwt.secret) else {
            throw Abort(.unauthorized)
        }
        guard let name = req.parameters.get("filename"), !name.contains("/"), !name.contains("..") else { throw Abort(.notFound) }
        let viewer = payload.sub.lowercased()
        let path = "/uploads/cv/\(name)"
        var allowed = name.hasPrefix(viewer + "_")
        if !allowed {
            struct R: Decodable { let job_id: String }
            for a in try await req.db.sql().raw("SELECT job_id::text AS job_id FROM job_applications WHERE cv_url = \(bind: path)")
                .all(decoding: R.self) where try await ApplicationStore.canManage(job: a.job_id, user: viewer, on: req.db.sql()) {
                allowed = true
                break
            }
        }
        guard allowed, FileManager.default.fileExists(atPath: "\(cvDir)/\(name)") else { throw Abort(.notFound) }
        return req.fileio.streamFile(at: "\(cvDir)/\(name)")
    }
}

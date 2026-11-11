import Vapor
import SQLKit

/// `/api/admin/hr/*`, the official account only: reviewing "Become HR"
/// requests, taking HR away, and the trial review of a new HR's first jobs
/// (migration 126).
struct AdminHRController {
    static func register(routes: any RoutesBuilder) {
        let a = routes.grouped("admin", "hr").grouped(AuthMiddleware())
            .grouped(AppRoleMiddleware(adminOnly: true)).grouped(RateLimitMiddleware.admin())
        a.get("requests", use: list)
        a.get("requests", ":id", use: get)
        a.post("requests", ":id", "decide", use: decide)
        a.post("recruiters", ":userId", "revoke", use: revoke)
        a.get("jobs", "pending", use: pendingJobs)
        a.post("jobs", ":postId", "decide", use: decideJob)
    }

    static func page(_ req: Request) -> (limit: Int, offset: Int) {
        (PostsController.clamp(try? req.query.get(Int.self, at: "limit"), 20, 1, 50),
         max(0, (try? req.query.get(Int.self, at: "offset")) ?? 0))
    }

    static func note(_ raw: String?) throws -> String? {
        let n = raw?.trimmedText.nilIfEmpty
        if let n, n.count > HRStore.maxNote { throw InlineError(.badRequest, "The note must be at most \(HRStore.maxNote) characters") }
        return n
    }

    static func list(_ req: Request) async throws -> DataResponse<[HRStore.Request]> {
        let status = (try? req.query.get(String.self, at: "status")) ?? "pending"
        guard ["pending", "approved", "rejected", "revoked"].contains(status) else { throw InlineError(.badRequest, "Unknown status") }
        let p = page(req)
        return DataResponse(data: try await HRStore.requests(status: status, limit: p.limit, offset: p.offset, on: req.db.sql()))
    }

    static func get(_ req: Request) async throws -> DataResponse<HRStore.Request> {
        guard let id = AdminModerationController.uuidParam(req, "id"),
              let r = try await HRStore.request(id, on: req.db.sql()) else { throw InlineError(.notFound, "Request not found") }
        return DataResponse(data: r)
    }

    struct DecideBody: Content { var decision: String?; var checklist: [String: Bool]?; var note: String? }

    static func decide(_ req: Request) async throws -> DataResponse<HRStore.Request> {
        guard let id = AdminModerationController.uuidParam(req, "id") else { throw InlineError(.notFound, "Request not found") }
        let b = try req.content.decode(DecideBody.self)
        guard let decision = b.decision, ["approve", "reject"].contains(decision) else {
            throw InlineError(.badRequest, "decision must be approve or reject")
        }
        let approve = decision == "approve"
        let note = try note(b.note)
        let checklist = (b.checklist ?? [:]).filter { HRStore.checklistItems.contains($0.key) }
        if approve {
            guard HRStore.checklistItems.allSatisfy({ checklist[$0] == true }) else {
                throw InlineError(.badRequest, "Tick every check before approving")
            }
            if let current = try await HRStore.request(id, on: req.db.sql()), let other = current.conflict_with {
                throw InlineError(.conflict, "\(other) is already HR for this tax code")
            }
        } else if note == nil {
            throw InlineError(.badRequest, "Say why it's rejected, the person will read it")
        }
        guard let decided = try await HRStore.decide(id, approve: approve, checklist: checklist, note: note,
                                                     reviewer: req.userID, on: req.db) else {
            throw InlineError(.conflict, "This request was already decided")
        }
        let person = decided.person.id, company = decided.company_name
        NotifyService.fireAndForget(req) { d, h, l in
            var payload: [String: Any] = ["companyName": company, "decision": decision, "mode": "work"]
            if let note { payload["note"] = note }
            _ = await NotifyService.pushUserNotification(
                userID: person, type: "hr_request_decided", entityType: "hr_request", entityID: id,
                payload: payload, on: d, hub: h, logger: l)
        }
        return DataResponse(data: decided)
    }

    struct RevokeBody: Content { var note: String? }
    struct Done: Content { var ok: Bool }

    static func revoke(_ req: Request) async throws -> Done {
        guard let user = AdminModerationController.uuidParam(req, "userId") else { throw InlineError(.notFound, "Not HR") }
        let note = try note(try req.content.decode(RevokeBody.self).note)
        guard note != nil else { throw InlineError(.badRequest, "Say why, the person will read it") }
        guard let applicants = try await HRStore.revoke(user, note: note, on: req.db) else { throw InlineError(.notFound, "Not HR") }
        NotifyService.fireAndForget(req) { d, h, l in
            _ = await NotifyService.pushUserNotification(
                userID: user, type: "hr_revoked", payload: ["note": note ?? "", "mode": "work"], on: d, hub: h, logger: l)
            // People who applied: the job is gone, and why that matters to them.
            for (applicant, title) in applicants {
                _ = await NotifyService.pushUserNotification(
                    userID: applicant, type: "job_removed", groupTargetID: user,
                    payload: ["jobTitle": title, "mode": "work"], on: d, hub: h, logger: l)
            }
        }
        return Done(ok: true)
    }

    static func pendingJobs(_ req: Request) async throws -> DataResponse<[HRStore.PendingJob]> {
        let p = page(req)
        return DataResponse(data: try await HRStore.pendingJobs(limit: p.limit, offset: p.offset, on: req.db.sql()))
    }

    struct JobDecideBody: Content { var action: String?; var reason: String? }

    static func decideJob(_ req: Request) async throws -> Done {
        guard let postID = AdminModerationController.uuidParam(req, "postId") else { throw InlineError(.notFound, "Job not found") }
        let b = try req.content.decode(JobDecideBody.self)
        guard let action = b.action, ["approve", "decline"].contains(action) else {
            throw InlineError(.badRequest, "action must be approve or decline")
        }
        let reason = try note(b.reason)
        if action == "decline", reason == nil { throw InlineError(.badRequest, "Say why it's declined, the HR will read it") }
        guard let job = try await HRStore.decideJob(postID, approve: action == "approve", on: req.db) else {
            throw InlineError(.notFound, "This job isn't waiting for review")
        }
        if action == "approve" {
            // Now it's live: the same side effects as posting straight away.
            await PostPublisher.afterPublish(req.application, queue: BackgroundJobs.queue(for: req), logger: req.logger,
                                             postID: postID, mode: job.mode, content: job.content ?? "",
                                             authorID: job.author_id)
        }
        let author = job.author_id, title = job.title, jobID = job.job_id
        NotifyService.fireAndForget(req) { d, h, l in
            var payload: [String: Any] = ["jobTitle": title, "jobId": jobID, "mode": "work"]
            if let reason { payload["reason"] = reason }
            _ = await NotifyService.pushUserNotification(
                userID: author, type: action == "approve" ? "job_approved" : "job_declined",
                entityType: "job", entityID: jobID, payload: payload, on: d, hub: h, logger: l)
        }
        return Done(ok: true)
    }
}

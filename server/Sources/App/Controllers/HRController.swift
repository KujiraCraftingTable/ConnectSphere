import Vapor
import SQLKit

/// `/api/hr/*`: asking to become a company's verified HR (migration 126),
/// the only people who can post jobs. Work mode only. The business
/// registration PDF is private: its owner and the app admin can open it.
struct HRController {
    static func register(routes: any RoutesBuilder, app: Application) {
        let hr = routes.grouped("hr").grouped(AuthMiddleware())
        hr.get("me", use: me)
        let limited = hr.grouped(RateLimitMiddleware.accountCodes())
        limited.post("email-code", use: emailCode)
        limited.on(.POST, "licence", body: .collect(maxSize: "10mb"), use: uploadLicence)
        limited.post("requests", use: submit)
        app.get("uploads", "hr", ":filename", use: serveLicence)
        // Job descriptions are public (served from uploads like images); only
        // a verified HR can add one.
        hr.on(.POST, "jd", body: .collect(maxSize: "10mb"), use: uploadJD)
        app.get("uploads", "jd", ":filename", use: serveJD)
    }

    /// Public, like the job it belongs to.
    static func serveJD(_ req: Request) async throws -> Response {
        guard let name = req.parameters.get("filename"), !name.contains("/"), !name.contains(".."),
              name.hasSuffix(".pdf"), FileManager.default.fileExists(atPath: "\(jdDir)/\(name)") else {
            throw Abort(.notFound)
        }
        let response = req.fileio.streamFile(at: "\(jdDir)/\(name)")
        response.headers.replaceOrAdd(name: .contentType, value: "application/pdf")
        return response
    }

    static let jdDir = UploadsController.uploadDir + "/jd"

    struct JDResponse: Content { var path: String }

    /// A job description PDF, at most 10 MB, saved under the HR's id so a job
    /// can only point at its own HR's file (see `PostService.createJobPost`).
    static func uploadJD(_ req: Request) async throws -> JDResponse {
        guard try await HRStore.recruiter(req.userID, on: req.db.sql()) != nil else {
            throw Abort(.forbidden, reason: "Only verified HR can post jobs")
        }
        struct FileBody: Content { var file: File }
        guard let file = try? req.content.decode(FileBody.self).file else { throw Abort(.badRequest, reason: "Missing file") }
        let bytes = Array(file.data.readableBytesView)
        guard bytes.starts(with: Array("%PDF".utf8)) else { throw Abort(.badRequest, reason: "The job description must be a PDF") }
        let name = "\(req.userID.lowercased())_\(UUID().uuidString.lowercased()).pdf"
        try FileManager.default.createDirectory(atPath: jdDir, withIntermediateDirectories: true)
        try await req.fileio.writeFile(ByteBuffer(bytes: bytes), at: "\(jdDir)/\(name)")
        return JDResponse(path: "/uploads/jd/\(name)")
    }

    static let licenceDir = UploadsController.uploadDir + "/hr"

    static func me(_ req: Request) async throws -> DataResponse<HRStore.MyStatus> {
        DataResponse(data: try await HRStore.status(of: req.userID, on: req.db.sql()))
    }

    /// A Work persona is needed: in Work mode, HR is who you are to applicants.
    static func requireWorkProfile(_ req: Request) async throws {
        try req.requireNotBanned(in: "work")
        try req.requireNotRestricted(in: "work")
        struct P: Decodable { let ok: Bool }
        guard try await req.db.sql().raw("SELECT (work_display_name IS NOT NULL) AS ok FROM users WHERE id = \(uuid: req.userID)")
            .first(decoding: P.self)?.ok == true else {
            throw InlineError(.badRequest, "Set up your Work profile first")
        }
    }

    /// Refuses when the person is HR already or has a request waiting.
    static func requireCanAsk(_ req: Request) async throws {
        let db = req.db.sql()
        if try await HRStore.recruiter(req.userID, on: db) != nil { throw InlineError(.conflict, "You're already a verified HR") }
        if try await HRStore.hasPending(req.userID, on: db) { throw InlineError(.conflict, "Your request is already waiting for review") }
    }

    /// A checked company email, lowercased.
    static func companyEmail(_ raw: String?) throws -> String {
        let email = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard email.count <= HRStore.maxEmail, let domain = HRStore.emailDomain(email) else {
            throw InlineError(.badRequest, "Enter a valid email")
        }
        guard !HRStore.freeMailDomains.contains(domain) else {
            throw InlineError(.badRequest, "Use your company email, not a personal one like \(domain)")
        }
        return email
    }

    struct EmailBody: Content { var email: String? }
    struct Sent: Content { var sent_to: String }

    static func emailCode(_ req: Request) async throws -> Sent {
        try await requireWorkProfile(req)
        try await requireCanAsk(req)
        let email = try companyEmail(try req.content.decode(EmailBody.self).email)
        let code = try await AccountCodeStore.issue(user: req.userID, purpose: .hrEmail, email: email, on: req.db.sql())
        try await Mailer(req).sendCode(code, to: email, kind: .hrEmail, minutes: AccountCodeStore.ttlMinutes)
        return Sent(sent_to: email)
    }

    struct LicenceResponse: Content { var path: String }

    /// The business registration certificate, a PDF of at most 10 MB.
    static func uploadLicence(_ req: Request) async throws -> LicenceResponse {
        try await requireWorkProfile(req)
        struct FileBody: Content { var file: File }
        guard let file = try? req.content.decode(FileBody.self).file else { throw InlineError(.badRequest, "Missing file") }
        let bytes = Array(file.data.readableBytesView)
        guard bytes.starts(with: Array("%PDF".utf8)) else { throw InlineError(.badRequest, "The business registration must be a PDF") }
        let name = "\(req.userID.lowercased())_\(UUID().uuidString.lowercased()).pdf"
        try FileManager.default.createDirectory(atPath: licenceDir, withIntermediateDirectories: true)
        try await req.fileio.writeFile(ByteBuffer(bytes: bytes), at: "\(licenceDir)/\(name)")
        return LicenceResponse(path: "/uploads/hr/\(name)")
    }

    static func serveLicence(_ req: Request) async throws -> Response {
        guard let token = req.query[String.self, at: "token"],
              let payload = try? JWTHS256.verify(token, secret: req.application.appEnv.jwt.secret),
              try await Session.isLive(payload, on: req.db.sql()) else {
            throw Abort(.unauthorized)
        }
        guard let name = req.parameters.get("filename"), !name.contains("/"), !name.contains("..") else { throw Abort(.notFound) }
        let viewer = payload.sub.lowercased()
        var allowed = name.hasPrefix(viewer + "_")
        if !allowed {
            struct R: Decodable { let app_role: String }
            allowed = try await req.db.sql().raw("SELECT app_role FROM users WHERE id = \(uuid: viewer)")
                .first(decoding: R.self)?.app_role == "admin"
        }
        guard allowed, FileManager.default.fileExists(atPath: "\(licenceDir)/\(name)") else { throw Abort(.notFound) }
        return req.fileio.streamFile(at: "\(licenceDir)/\(name)")
    }

    struct SubmitBody: Content {
        var company_name: String?
        var tax_code: String?
        var website: String?
        var email: String?
        var code: String?
        var licence_path: String?
    }

    static func submit(_ req: Request) async throws -> Response {
        try await requireWorkProfile(req)
        try await requireCanAsk(req)
        let b = try req.content.decode(SubmitBody.self)
        let me = req.userID.lowercased()
        let name = (b.company_name ?? "").trimmedText
        guard !name.isEmpty else { throw InlineError(.badRequest, "Company name is required") }
        guard name.count <= HRStore.maxCompanyName else {
            throw InlineError(.badRequest, "Company name must be at most \(HRStore.maxCompanyName) characters")
        }
        let tax = (b.tax_code ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard HRStore.validTaxCode(tax) else {
            throw InlineError(.badRequest, "Tax code must be 10 digits, or 13 for a branch (0101234567-001)")
        }
        let website = (b.website ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard website.count <= HRStore.maxWebsite, HRStore.websiteHost(website) != nil else {
            throw InlineError(.badRequest, "Enter the company's website")
        }
        let email = try companyEmail(b.email)
        guard HRStore.sameCompanyDomain(email: email, website: website) else {
            throw InlineError(.badRequest, "The email must be on the company website's domain")
        }
        // Only a PDF this person uploaded.
        let path = b.licence_path ?? ""
        let file = String(path.dropFirst("/uploads/hr/".count))
        guard path.hasPrefix("/uploads/hr/"), file.hasPrefix(me + "_"), !file.contains("/"), !file.contains(".."),
              FileManager.default.fileExists(atPath: "\(licenceDir)/\(file)") else {
            throw InlineError(.badRequest, "Add the business registration PDF")
        }
        // Last, so a typo elsewhere doesn't burn a try. The code must be the
        // one sent to this very address.
        let proved = try await AccountCodeStore.consume(user: me, purpose: .hrEmail, code: b.code ?? "", on: req.db.sql())
        guard proved.lowercased() == email else {
            throw InlineError(.badRequest, "That code was sent to another email. Ask for a new one")
        }
        let id = try await HRStore.create(.init(user: me, companyName: name, taxCode: HRStore.normalizedTaxCode(tax),
                                                website: website, workEmail: email, licencePath: path), on: req.db.sql())
        // Tell the admin there's a request to review.
        NotifyService.fireAndForget(req) { d, h, l in
            struct A: Decodable { let id: String }
            guard let admin = try? await d.raw("SELECT id::text AS id FROM users WHERE app_role = 'admin' LIMIT 1")
                .first(decoding: A.self) else { return }
            _ = await NotifyService.pushUserNotification(
                userID: admin.id, type: "hr_request_new", actorID: me, entityType: "hr_request", entityID: id,
                payload: ["companyName": name, "mode": "work"], actorMode: "work", on: d, hub: h, logger: l)
        }
        let res = try await DataResponse(data: try await HRStore.status(of: me, on: req.db.sql())).encodeResponse(for: req)
        res.status = .created
        return res
    }
}

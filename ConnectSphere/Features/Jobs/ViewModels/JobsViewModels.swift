import Foundation
import Observation

/// The Jobs tab: For you (recommended), Search (with filters), Saved,
/// and Applied (your applications and where each stands).
@MainActor
@Observable
final class JobsHomeViewModel {
    enum Segment: Hashable { case forYou, search, saved, applied }

    var segment: Segment = .forYou
    var filters = JobsRepository.Filters()
    private(set) var recommended: [JobListing] = []
    private(set) var results: [JobListing] = []
    private(set) var saved: [JobListing] = []
    private(set) var applications: [JobApplication] = []
    private(set) var isLoading = false
    var errorMessage: String?

    private let repository = JobsRepository()
    private var searchTask: Task<Void, Never>?

    var shown: [JobListing] {
        switch segment {
        case .forYou: recommended
        case .search: results
        case .saved: saved
        case .applied: []
        }
    }

    var isEmpty: Bool { segment == .applied ? applications.isEmpty : shown.isEmpty }

    func load(token: String) async {
        isLoading = isEmpty
        defer { isLoading = false }
        do {
            switch segment {
            case .forYou: recommended = try await repository.recommended(token: token)
            case .search: results = try await repository.search(filters, token: token)
            case .saved: saved = try await repository.saved(token: token)
            case .applied: applications = try await repository.myApplications(token: token)
            }
            errorMessage = nil
        } catch {
            errorMessage = friendlyError(error)
        }
    }

    /// Typing and filter changes search again a moment later.
    func searchSoon(token: String) {
        searchTask?.cancel()
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await load(token: token)
        }
    }

    /// Shown at once everywhere the job appears; put back if refused.
    func toggleSave(_ job: JobListing, token: String) async {
        let now = !job.saved
        apply(job.id) { $0.saved = now; $0.interestedCount += now ? 1 : -1 }
        do {
            try await repository.setSaved(now, jobId: job.id, token: token)
            if !now { saved.removeAll { $0.id == job.id } }
        } catch {
            apply(job.id) { $0.saved = !now; $0.interestedCount += now ? -1 : 1 }
            errorMessage = friendlyError(error)
        }
    }

    /// A change made on the job's own screen.
    func updated(_ job: JobListing) { apply(job.id) { $0 = job } }

    private func apply(_ id: String, _ change: (inout JobListing) -> Void) {
        if let i = recommended.firstIndex(where: { $0.id == id }) { change(&recommended[i]) }
        if let i = results.firstIndex(where: { $0.id == id }) { change(&results[i]) }
        if let i = saved.firstIndex(where: { $0.id == id }) { change(&saved[i]) }
    }
}

/// One job's screen.
@MainActor
@Observable
final class JobDetailViewModel {
    private(set) var job: JobListing?
    private(set) var isLoading = false
    var errorMessage: String?

    let jobId: String
    private let repository = JobsRepository()

    init(jobId: String, preloaded: JobListing? = nil) {
        self.jobId = jobId
        self.job = preloaded
    }

    func load(token: String) async {
        isLoading = job == nil
        defer { isLoading = false }
        do { job = try await repository.job(id: jobId, token: token) }
        catch { if job == nil { errorMessage = friendlyError(error) } }
    }

    /// After applying from the sheet.
    func applied(_ application: JobApplication) {
        job?.applicationStatus = application.status
    }

    func toggleSave(token: String) async {
        guard var j = job else { return }
        let before = j
        j.saved.toggle()
        j.interestedCount += j.saved ? 1 : -1
        job = j
        do { try await repository.setSaved(j.saved, jobId: jobId, token: token) }
        catch {
            job = before
            errorMessage = friendlyError(error)
        }
    }
}

/// A company page's Jobs tab.
@MainActor
@Observable
final class CompanyJobsViewModel {
    private(set) var jobs: [JobListing] = []
    private(set) var loaded = false
    private let repository = JobsRepository()

    func load(companyId: String, token: String) async {
        jobs = (try? await repository.companyJobs(companyId: companyId, token: token)) ?? []
        loaded = true
    }
}

/// The Apply sheet: an optional note and an optional PDF CV, sent with
/// your Work profile.
@MainActor
@Observable
final class ApplyViewModel {
    static let noteLimit = 1000
    static let cvLimit = 10 * 1024 * 1024

    var note = ""
    private(set) var cvName: String?
    private(set) var cvUrl: String?
    private(set) var isUploadingCV = false
    private(set) var isSubmitting = false
    var errorMessage: String?

    let jobId: String
    private let repository = JobsRepository()

    init(jobId: String) { self.jobId = jobId }

    private var trimmedNote: String { note.trimmingCharacters(in: .whitespacesAndNewlines) }
    var noteTooLong: Bool { trimmedNote.count > Self.noteLimit }
    var canSubmit: Bool { !noteTooLong && !isUploadingCV && !isSubmitting }

    /// A file picked from Files: read it, check it, upload it.
    func attachCV(at url: URL, token: String) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            errorMessage = Bundle.app.loc("Couldn't read that file.")
            return
        }
        guard data.count <= Self.cvLimit else {
            errorMessage = Bundle.app.loc("The CV must be 10 MB or smaller.")
            return
        }
        isUploadingCV = true
        defer { isUploadingCV = false }
        do {
            cvUrl = try await repository.uploadCV(data, fileName: url.lastPathComponent, token: token)
            cvName = url.lastPathComponent
            errorMessage = nil
        } catch {
            errorMessage = friendlyError(error)
        }
    }

    func removeCV() {
        cvUrl = nil
        cvName = nil
    }

    /// The application, or nil (with a message) if it was refused.
    func submit(token: String) async -> JobApplication? {
        guard canSubmit else { return nil }
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            let note = trimmedNote.isEmpty ? nil : trimmedNote
            return try await repository.apply(jobId: jobId, note: note, cvUrl: cvUrl, token: token)
        } catch {
            errorMessage = friendlyError(error)
            return nil
        }
    }
}

/// A job's applicants, for its poster or company admins.
@MainActor
@Observable
final class ApplicantsViewModel {
    /// nil = everyone.
    var filter: String?
    private(set) var applications: [JobApplication] = []
    private(set) var isLoading = false
    private(set) var openingChatFor: String?
    var errorMessage: String?

    let jobId: String
    private let repository = JobsRepository()

    /// Moves waiting out their Undo window, by application id: the status
    /// shown before the first of them, and the send that's waiting.
    private var pending: [String: (before: JobApplication, send: Task<Void, Never>)] = [:]
    /// The applicant is told about every move, so it waits this long, as long
    /// as the Undo toast shows, before it's sent.
    static let undoWindow: Duration = .seconds(5)

    init(jobId: String) { self.jobId = jobId }

    var shown: [JobApplication] {
        guard let filter else { return applications }
        return applications.filter { $0.status == filter }
    }

    func count(_ status: String?) -> Int {
        guard let status else { return applications.count }
        return applications.filter { $0.status == status }.count
    }

    func load(token: String) async {
        isLoading = applications.isEmpty
        defer { isLoading = false }
        do {
            applications = try await repository.applicants(jobId: jobId, token: token)
            errorMessage = nil
        } catch {
            errorMessage = friendlyError(error)
        }
    }

    /// Shown at once; put back if refused. The applicant hears about every
    /// step except "viewed".
    func setStatus(_ status: String, for application: JobApplication, token: String) async {
        guard let i = applications.firstIndex(where: { $0.id == application.id }),
              applications[i].status != status else { return }
        let before = applications[i]
        applications[i].status = status
        await send(status, applicationId: application.id, restoringTo: before, token: token)
    }

    private func send(_ status: String, applicationId: String, restoringTo before: JobApplication, token: String) async {
        do {
            let updated = try await repository.setStatus(status, applicationId: applicationId, token: token)
            if let j = applications.firstIndex(where: { $0.id == updated.id }) { applications[j] = updated }
        } catch {
            if let j = applications.firstIndex(where: { $0.id == before.id }) { applications[j] = before }
            errorMessage = friendlyError(error)
        }
    }

    /// A move the manager made: shown at once, sent once the Undo window has
    /// passed. A second move inside the window replaces the first, so the
    /// applicant only hears about where they ended up. The send keeps the view
    /// model alive, so leaving the screen doesn't drop it.
    func stage(_ status: String, for application: JobApplication, token: String) {
        guard let i = applications.firstIndex(where: { $0.id == application.id }),
              applications[i].status != status else { return }
        let before = pending[application.id]?.before ?? applications[i]
        pending[application.id]?.send.cancel()
        applications[i].status = status
        let send = Task { [self] in
            try? await Task.sleep(for: Self.undoWindow)
            guard !Task.isCancelled else { return }
            pending[application.id] = nil
            // Back where it started: nothing to tell anyone.
            guard before.status != status else { return }
            await send(status, applicationId: application.id, restoringTo: before, token: token)
        }
        pending[application.id] = (before, send)
    }

    /// Puts the application back as it was before the waiting move; nothing is sent.
    func undo(_ applicationId: String) {
        guard let staged = pending.removeValue(forKey: applicationId) else { return }
        staged.send.cancel()
        if let i = applications.firstIndex(where: { $0.id == applicationId }) { applications[i] = staged.before }
    }

    /// Opening a new application marks it "viewed".
    func opened(_ application: JobApplication, token: String) async {
        guard application.status == "applied" else { return }
        await setStatus("viewed", for: application, token: token)
    }

    /// A Work chat with the applicant; its id, or nil if it couldn't open.
    func openChat(with application: JobApplication, token: String) async -> String? {
        openingChatFor = application.id
        defer { openingChatFor = nil }
        do {
            return try await MessageRepository().openConversation(otherUserId: application.applicant.id, mode: "work", token: token)
        } catch {
            errorMessage = friendlyError(error)
            return nil
        }
    }
}

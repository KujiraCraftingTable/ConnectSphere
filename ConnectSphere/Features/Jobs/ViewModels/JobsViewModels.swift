import Foundation
import Observation

/// The Jobs tab: For you (recommended), Search (with filters), Saved.
@MainActor
@Observable
final class JobsHomeViewModel {
    enum Segment: Hashable { case forYou, search, saved }

    var segment: Segment = .forYou
    var filters = JobsRepository.Filters()
    private(set) var recommended: [JobListing] = []
    private(set) var results: [JobListing] = []
    private(set) var saved: [JobListing] = []
    private(set) var isLoading = false
    var errorMessage: String?

    private let repository = JobsRepository()
    private var searchTask: Task<Void, Never>?

    var shown: [JobListing] {
        switch segment {
        case .forYou: recommended
        case .search: results
        case .saved: saved
        }
    }

    func load(token: String) async {
        isLoading = shown.isEmpty
        defer { isLoading = false }
        do {
            switch segment {
            case .forYou: recommended = try await repository.recommended(token: token)
            case .search: results = try await repository.search(filters, token: token)
            case .saved: saved = try await repository.saved(token: token)
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

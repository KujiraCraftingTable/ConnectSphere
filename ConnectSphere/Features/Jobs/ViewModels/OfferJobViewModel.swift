import Foundation
import Observation

/// The HR's own open jobs, to offer one on an "Open to work" post.
@MainActor
@Observable
final class OfferJobViewModel {
    private(set) var jobs: [JobListing] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private let repository = JobsRepository()

    func load(token: String) async {
        isLoading = jobs.isEmpty
        defer { isLoading = false }
        do {
            jobs = try await repository.mine(token: token)
            errorMessage = nil
        } catch {
            errorMessage = friendlyError(error)
        }
    }
}

import Foundation
import Observation

/// The earlier versions of one post or comment, newest first.
@MainActor
@Observable
final class EditHistoryViewModel {
    let subject: EditHistorySubject
    private(set) var revisions: [EditRevisionDTO] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    private let repository = EditHistoryRepository()

    init(subject: EditHistorySubject) { self.subject = subject }

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            revisions = try await repository.fetch(subject)
        } catch APIError.serverError(404, _) {
            errorMessage = Bundle.app.loc("This content is no longer available")
        } catch {
            errorMessage = friendlyError(error)
        }
    }
}

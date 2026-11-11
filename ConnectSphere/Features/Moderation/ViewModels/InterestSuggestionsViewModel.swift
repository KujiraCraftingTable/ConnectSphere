import Foundation
import Observation

/// Admin tools › Interest suggestions: what people asked to add to the
/// interest picker, approved into the catalog or rejected.
@MainActor
@Observable
final class InterestSuggestionsViewModel {
    private(set) var suggestions: [InterestSuggestion] = []
    private(set) var categories: [InterestCategoryOption] = []
    private(set) var isLoading = false
    /// Suggestions with an approve/reject in flight.
    private(set) var processing: Set<String> = []
    var errorMessage: String?

    private let repository = InterestSuggestionsRepository()

    func load(token: String) async {
        isLoading = true
        defer { isLoading = false }
        do {
            (suggestions, categories) = try await repository.list(token: token)
        } catch where !error.isCancellation {
            errorMessage = friendlyError(error)
        } catch {}
    }

    /// Adds it to the catalog; true when it worked, so the form can close.
    func approve(_ s: InterestSuggestion, nameEn: String, nameVi: String, category: String,
                 allowsSpecific: Bool, token: String) async -> Bool {
        processing.insert(s.id)
        defer { processing.remove(s.id) }
        do {
            try await repository.approve(text: s.text, nameEn: nameEn, nameVi: nameVi, category: category,
                                         allowsSpecific: allowsSpecific, token: token)
            suggestions.removeAll { $0.id == s.id }
            return true
        } catch {
            errorMessage = friendlyError(error)
            return false
        }
    }

    func reject(_ s: InterestSuggestion, token: String) async -> Bool {
        processing.insert(s.id)
        defer { processing.remove(s.id) }
        do {
            try await repository.reject(text: s.text, token: token)
            suggestions.removeAll { $0.id == s.id }
            return true
        } catch {
            errorMessage = friendlyError(error)
            return false
        }
    }
}

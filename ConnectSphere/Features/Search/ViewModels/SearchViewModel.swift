import Foundation
import Observation

@MainActor
@Observable
class SearchViewModel {
    var results: [UserProfile] = []
    var isLoading = false
    var error: String?
    var aiReasoning: String = ""
    var aiCriteria: AISearchCriteriaDTO? = nil
    var aiTips: String = ""
    var lastAIPrompt: String = ""
    var aiSearchFailed = false
    var suggestions: [String] = []

    var currentUserId: String? = nil

    private let repository = UserRepository()
    private var searchTask: Task<Void, Never>?

    // MARK: - Basic text search (debounced)

    func search(query: String, mode: AppMode) {
        searchTask?.cancel()
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            Task { await loadAll(mode: mode) }
            return
        }
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            await performTextSearch(query: query, mode: mode)
        }
    }

    func loadAll(mode: AppMode) async {
        isLoading = true
        error = nil
        aiReasoning = ""
        aiCriteria = nil
        aiSearchFailed = false
        async let usersResult = repository.fetchUsers(mode: mode)
        async let suggestionsResult = repository.fetchSuggestions(mode: mode)
        do {
            results = excluding(try await usersResult)
        } catch {
            self.error = error.localizedDescription
        }
        if let fetched = try? await suggestionsResult, !fetched.isEmpty {
            suggestions = fetched
        }
        isLoading = false
    }

    // MARK: - AI semantic search

    func aiSearch(prompt: String, mode: AppMode, radiusKm: Int? = nil) async {
        guard !prompt.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        isLoading = true
        error = nil
        aiReasoning = ""
        aiCriteria = nil
        aiTips = ""
        aiSearchFailed = false
        lastAIPrompt = prompt.trimmingCharacters(in: .whitespaces)
        do {
            let result = try await repository.aiSearch(prompt: prompt, mode: mode, radiusKm: radiusKm)
            results     = excluding(result.users)
            aiReasoning = result.reasoning
            aiCriteria  = result.criteria
            aiTips      = result.tips
        } catch {
            print("❌ aiSearch failed: \(error)")
            aiSearchFailed = true
        }
        print("✅ aiSearch done — criteria: \(String(describing: aiCriteria)), tips: '\(aiTips)'")
        isLoading = false
    }

    // MARK: - Private

    private func excluding(_ list: [UserProfile]) -> [UserProfile] {
        guard let id = currentUserId else { return list }
        return list.filter { $0.id != id }
    }

    private func performTextSearch(query: String, mode: AppMode) async {
        isLoading = true
        error = nil
        aiReasoning = ""
        aiCriteria = nil
        lastAIPrompt = ""
        do {
            let users = try await repository.fetchUsers(mode: mode, search: query)
            results = excluding(users)
        } catch {
            if !(error is CancellationError) {
                self.error = error.localizedDescription
            }
        }
        isLoading = false
    }
}

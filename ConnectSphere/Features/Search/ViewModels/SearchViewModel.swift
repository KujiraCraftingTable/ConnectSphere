import Foundation
import Observation

@MainActor
@Observable
class SearchViewModel {
    var results: [UserProfile] = []
    var isLoading = false
    var error: String?
    var aiCriteria: AISearchCriteriaDTO? = nil
    /// Parts of the query the AI could not understand or apply. Empty = show nothing.
    var searchWarnings: [SearchWarningDTO] = []
    var lastAIPrompt: String = ""
    /// Params of the last AI search, kept so a location clarification can re-run
    /// exactly the same query with the now-known place.
    private var lastMode: AppMode? = nil
    private var lastRadiusKm: Int? = nil
    /// Set when a clarification was submitted but the backend still couldn't place
    /// it — the box switches to "flagged for review" instead of asking again.
    var clarifyUnconfirmed = false
    var isClarifying = false
    var aiSearchFailed = false
    var suggestions: [String] = []
    var entitySuggestions: [EntitySuggestionDTO] = []   // gray "did you mean …?" area
    var matchEvidence: [String: [MatchEvidenceDTO]] = [:]   // userId → match reasons (mini CV)

    var currentUserId: String? = nil

    private let repository = UserRepository()
    private var searchTask: Task<Void, Never>?
    /// Incremented every time a new load starts — a late response from an older load
    /// (e.g. switching modes in quick succession) is discarded instead of overwriting newer results
    private var loadGeneration = 0

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
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        error = nil
        aiCriteria = nil
        searchWarnings = []
        aiSearchFailed = false
        lastAIPrompt = ""   // browse list, not AI results — fully exit AI state
        entitySuggestions = []
        matchEvidence = [:]
        async let usersResult = repository.fetchUsers(mode: mode)
        async let suggestionsResult = repository.fetchSuggestions(mode: mode)
        do {
            let users = excluding(try await usersResult)
            guard generation == loadGeneration else { return }
            results = users
        } catch {
            guard generation == loadGeneration else { return }
            // Don't keep the old list — it could be data from a different mode, causing the wrong mode to display
            results = []
            self.error = error.localizedDescription
        }
        if let fetched = try? await suggestionsResult, !fetched.isEmpty,
           generation == loadGeneration {
            suggestions = fetched
        }
        if generation == loadGeneration { isLoading = false }
    }

    // MARK: - AI semantic search

    func aiSearch(prompt: String, mode: AppMode, radiusKm: Int? = nil) async {
        guard !prompt.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        loadGeneration += 1
        isLoading = true
        error = nil
        aiCriteria = nil
        searchWarnings = []
        aiSearchFailed = false
        entitySuggestions = []
        matchEvidence = [:]
        clarifyUnconfirmed = false
        lastAIPrompt = prompt.trimmingCharacters(in: .whitespaces)
        lastMode     = mode
        lastRadiusKm = radiusKm
        do {
            let result = try await repository.aiSearch(prompt: prompt, mode: mode, radiusKm: radiusKm)
            results           = excluding(result.users)
            aiCriteria        = result.criteria
            searchWarnings    = result.warnings
            entitySuggestions = result.suggestions
            matchEvidence     = result.evidence
        } catch {
            print("❌ aiSearch failed: \(error)")
            // Don't keep the old results (from browse or a previous AI search) — otherwise
            // results.isEmpty in SearchView stays false and the error/kujiraRetryState
            // never displays, so the user sees stale data as if it still matched.
            results = []
            aiSearchFailed = true
        }
        print("✅ aiSearch done — criteria: \(String(describing: aiCriteria))")
        isLoading = false
    }

    /// User answers "what is 'landmark hcmc'?" in the warning box. The backend
    /// geocodes their answer and records the mapping; if it could place it, we
    /// re-run the same search straight away so they get results without retyping.
    func clarifyLocation(alias: String, canonical: String) async {
        let answer = canonical.trimmingCharacters(in: .whitespaces)
        guard !answer.isEmpty, !isClarifying else { return }
        isClarifying = true
        defer { isClarifying = false }

        do {
            let result = try await repository.clarifyLocation(alias: alias, canonical: answer)
            if result.resolved, let mode = lastMode, !lastAIPrompt.isEmpty {
                // Clearing the warning first means the re-run can only ever surface a
                // *fresh* warning — the clarified place now resolves via the alias
                // pool, so this can't bounce back into the same clarify prompt.
                searchWarnings = []
                await aiSearch(prompt: lastAIPrompt, mode: mode, radiusKm: lastRadiusKm)
            } else {
                // Saved as pending for the data controller, but we still can't place
                // it — say so rather than leaving the user retyping into a void.
                clarifyUnconfirmed = true
            }
        } catch {
            print("❌ clarifyLocation failed: \(error)")
            clarifyUnconfirmed = true
        }
    }

    /// User taps "that's right" on a suggestion → save the alias, then remove the suggestion from the UI.
    func confirmAlias(keyword: String, candidate: EntityCandidateDTO) async {
        do {
            try await repository.confirmAlias(keyword: keyword, entityId: candidate.entity_id)
            entitySuggestions.removeAll { $0.keyword == keyword }
        } catch {
            print("❌ confirmAlias failed: \(error)")
        }
    }

    // MARK: - Private

    private func excluding(_ list: [UserProfile]) -> [UserProfile] {
        guard let id = currentUserId else { return list }
        return list.filter { $0.id != id }
    }

    private func performTextSearch(query: String, mode: AppMode) async {
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        error = nil
        aiCriteria = nil
        searchWarnings = []
        lastAIPrompt = ""
        entitySuggestions = []
        matchEvidence = [:]
        do {
            let users = try await repository.fetchUsers(mode: mode, search: query)
            guard generation == loadGeneration else { return }
            results = excluding(users)
        } catch {
            guard generation == loadGeneration else { return }
            if !(error is CancellationError) {
                results = []
                self.error = error.localizedDescription
            }
        }
        if generation == loadGeneration { isLoading = false }
    }
}

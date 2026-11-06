import Foundation
import Observation

/// What the Search tab is looking for.
enum SearchScope: String, CaseIterable, Identifiable {
    /// `companies` is Work mode only, and searches itself
    /// (`CompanySearchResults`), so the people/posts searches skip it.
    case people, posts, companies
    var id: String { rawValue }
}

@MainActor
@Observable
class SearchViewModel {
    var scope: SearchScope = .people
    var results: [UserProfile] = []
    /// Posts scope. Keyword search arrives relevance-ranked from the server;
    /// AI search adds `postMatchScores` (post id → 0…1), already sorted by it.
    var postResults: [Post] = []
    var postMatchScores: [String: Double] = [:]
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
    /// it, the box switches to "flagged for review" instead of asking again.
    var clarifyUnconfirmed = false
    var isClarifying = false
    var aiSearchFailed = false
    var suggestions: [String] = []
    var entitySuggestions: [EntitySuggestionDTO] = []   // gray "did you mean …?" area
    var matchEvidence: [String: [MatchEvidenceDTO]] = [:]   // userId → match reasons (mini CV)
    /// The last AI people search's id on the server. Refinements, taps,
    /// "Not a fit" and the "why they fit you" lines all refer to it.
    private(set) var searchSessionId: String?
    /// userId → one "why they fit you" sentence, filled in after the results show.
    var fitReasons: [String: String] = [:]
    var isRefining = false
    /// People whose name is the prompt ("Lý Thảo"), shown while the AI search
    /// runs, no need to wait on the LLM for a name. A topic prompt matches no
    /// name, so it shows nothing here.
    private(set) var quickMatches: [UserProfile] = []

    static func isNameMatch(_ user: UserProfile, prompt: String) -> Bool {
        let q = InterestCatalogViewModel.fold(prompt.trimmingCharacters(in: .whitespaces))
        guard q.count >= 3, q.split(separator: " ").count <= 4 else { return false }
        return [user.name, user.username].contains { InterestCatalogViewModel.fold($0).contains(q) }
    }
    /// Shown under the refine chips; the current results stay on screen.
    var refineError: String?

    var currentUserId: String? = nil

    /// Paging state for the plain browse/text-search list. Mirrors
    /// `FeedViewModel`'s `.connections` offset pattern. Does NOT apply to
    /// `aiSearch`, which returns one full ranked result set with no
    /// limit/offset support on the backend.
    private(set) var isLoadingMore = false
    private(set) var hasMore = true
    private var offset = 0
    private let pageSize = 20
    /// nil = last load was `loadAll` (browse); set = the active text search
    /// query, lets `loadMore()` continue the right fetch with no parameter.
    private var lastQuery: String? = nil

    private let repository = UserRepository()
    private let postRepository = PostRepository()
    private var searchTask: Task<Void, Never>?
    /// Incremented every time a new load starts. A late response from an older load
    /// (e.g. switching modes in quick succession) is discarded instead of overwriting newer results
    private var loadGeneration = 0

    // MARK: - Basic text search (debounced)

    /// Keyword search for the current `scope`, 300 ms after typing stops. An
    /// empty query returns People to the browse list and clears Posts.
    func search(query: String, mode: AppMode) {
        searchTask?.cancel()
        guard scope != .companies else { return }
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            if scope == .people {
                Task { await loadAll(mode: mode) }
            } else {
                clearPosts()
            }
            return
        }
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            if scope == .people {
                await performTextSearch(query: query, mode: mode)
            } else {
                await performPostSearch(query: query, mode: mode)
            }
        }
    }

    /// AI search for the current `scope`. Run on submit, not per keystroke,
    /// since each run is an LLM call.
    func submitAI(prompt: String, mode: AppMode, radiusKm: Int?) async {
        searchTask?.cancel()
        guard scope != .companies else { return }
        if scope == .people {
            await aiSearch(prompt: prompt, mode: mode, radiusKm: radiusKm)
        } else {
            await aiPostSearch(prompt: prompt, mode: mode)
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
        lastAIPrompt = ""   // browse list, not AI results. Fully exit AI state
        entitySuggestions = []
        matchEvidence = [:]
        offset = 0
        lastQuery = nil
        async let usersResult = repository.fetchUsers(mode: mode, limit: pageSize, offset: 0)
        async let suggestionsResult = repository.fetchSuggestions(mode: mode)
        do {
            let users = excluding(try await usersResult)
            guard generation == loadGeneration else { return }
            results = users
            offset = pageSize
            hasMore = users.count == pageSize
        } catch {
            guard generation == loadGeneration else { return }
            // Don't keep the old list. It could be data from a different mode, causing the wrong mode to display
            results = []
            hasMore = false
            self.error = error.localizedDescription
        }
        if let fetched = try? await suggestionsResult, !fetched.isEmpty,
           generation == loadGeneration {
            suggestions = fetched
        }
        if generation == loadGeneration { isLoading = false }
    }

    /// Fetches the next page of the current browse/text-search list and
    /// appends it, called when the last visible row appears (see
    /// `SearchView`'s `.onAppear` on each row). No-op mid-AI-search (that
    /// path has no pagination; see this file's paging-state doc comment).
    func loadMore(mode: AppMode) async {
        guard !isLoadingMore, hasMore, lastAIPrompt.isEmpty else { return }
        if scope == .posts {
            await loadMorePosts(mode: mode)
            return
        }
        loadGeneration += 1
        let generation = loadGeneration
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let fetched = try await repository.fetchUsers(mode: mode, search: lastQuery, limit: pageSize, offset: offset)
            guard generation == loadGeneration else { return }
            results.append(contentsOf: excluding(fetched))
            offset += pageSize
            hasMore = fetched.count == pageSize
        } catch {
            guard generation == loadGeneration else { return }
            // Leave the already-loaded rows in place. Only stop trying to
            // load further, don't wipe what's already showing.
            hasMore = false
        }
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
        searchSessionId = nil
        fitReasons = [:]
        quickMatches = []
        let generation = loadGeneration
        let quick = Task {
            guard let users = try? await repository.fetchUsers(mode: mode, search: prompt, limit: 5, offset: 0),
                  generation == loadGeneration, isLoading else { return }
            quickMatches = excluding(users).filter { Self.isNameMatch($0, prompt: prompt) }
        }
        defer {
            quick.cancel()
            quickMatches = []
        }
        do {
            apply(try await repository.aiSearch(prompt: prompt, mode: mode, radiusKm: radiusKm))
        } catch {
            print("❌ aiSearch failed: \(error)")
            // Don't keep the old results (from browse or a previous AI search), otherwise
            // results.isEmpty in SearchView stays false and the error/kujiraRetryState
            // never displays, so the user sees stale data as if it still matched.
            results = []
            aiSearchFailed = true
        }
        print("✅ aiSearch done, criteria: \(String(describing: aiCriteria))")
        isLoading = false
    }

    private func apply(_ result: UserRepository.AISearchResult) {
        results           = excluding(result.users)
        aiCriteria        = result.criteria
        searchWarnings    = result.warnings
        entitySuggestions = result.suggestions
        matchEvidence     = result.evidence
        searchSessionId   = result.sessionId
        fitReasons        = [:]
    }

    // MARK: - Refine, feedback, "why they fit you" (AI_SEARCH_REVIEW.md S3–S4)

    enum Refinement { case text(String), moreLike(userId: String), closer }

    /// Re-runs the last AI people search with one change, keeping the prompt.
    func refine(_ refinement: Refinement, mode: AppMode) async {
        guard let sid = searchSessionId, !isRefining else { return }
        if case .text(let t) = refinement, t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return }
        loadGeneration += 1
        let generation = loadGeneration
        isRefining = true
        refineError = nil
        defer { isRefining = false }
        do {
            let result: UserRepository.AISearchResult
            switch refinement {
            case .text(let t):
                result = try await repository.refineAISearch(sessionId: sid, mode: mode,
                                                             refine: t.trimmingCharacters(in: .whitespacesAndNewlines))
            case .moreLike(let uid):
                result = try await repository.refineAISearch(sessionId: sid, mode: mode, moreLike: uid)
            case .closer:
                result = try await repository.refineAISearch(sessionId: sid, mode: mode, closer: true)
            }
            guard generation == loadGeneration else { return }
            apply(result)
        } catch {
            guard generation == loadGeneration else { return }
            #if DEBUG
            print("❌ refine failed: \(error)")
            #endif
            refineError = Bundle.app.loc("Couldn't refine the search. Please try again.")
        }
    }

    /// "Not a fit": the person leaves this list now, and sinks in your
    /// searches for the next 30 days.
    func notAFit(userId: String) {
        results.removeAll { $0.id == userId }
        report(userId: userId, kind: "dismiss")
    }

    /// A result was opened.
    func didOpenResult(userId: String) {
        report(userId: userId, kind: "tap")
    }

    private func report(userId: String, kind: String) {
        guard let sid = searchSessionId else { return }
        Task {
            do { try await repository.reportSearchEvent(sessionId: sid, userId: userId, kind: kind) }
            catch {
                #if DEBUG
                print("⚠️ search event \(kind) not sent: \(error)")
                #endif
            }
        }
    }

    /// Fetches the "why they fit you" lines for the current results. Missing
    /// lines just aren't shown. The match reasons are already on screen.
    func loadFitReasons(lang: String) async {
        guard let sid = searchSessionId, fitReasons.isEmpty else { return }
        do {
            let reasons = try await repository.explainSearch(sessionId: sid, lang: lang)
            guard sid == searchSessionId else { return }
            fitReasons = reasons
        } catch {
            #if DEBUG
            print("⚠️ fit reasons failed: \(error)")
            #endif
        }
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
                // *fresh* warning, the clarified place now resolves via the alias
                // pool, so this can't bounce back into the same clarify prompt.
                searchWarnings = []
                await aiSearch(prompt: lastAIPrompt, mode: mode, radiusKm: lastRadiusKm)
            } else {
                // Saved as pending for the data controller, but we still can't place
                // it, say so rather than leaving the user retyping into a void.
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

    // MARK: - Posts

    func clearPosts() {
        loadGeneration += 1
        postResults = []
        postMatchScores = [:]
        resetAIState()
        isLoading = false
        hasMore = false
    }

    /// Removes a post the user just deleted from whichever list shows it.
    func removePost(id: String) {
        postResults.removeAll { $0.id == id }
    }

    private func performPostSearch(query: String, mode: AppMode) async {
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        error = nil
        resetAIState()
        postMatchScores = [:]
        offset = 0
        lastQuery = query
        do {
            let posts = try await postRepository.searchPosts(query, mode: mode, limit: pageSize, offset: 0)
            guard generation == loadGeneration else { return }
            postResults = posts
            offset = pageSize
            hasMore = posts.count == pageSize
        } catch {
            guard generation == loadGeneration else { return }
            if !(error is CancellationError) {
                postResults = []
                hasMore = false
                self.error = error.localizedDescription
            }
        }
        if generation == loadGeneration { isLoading = false }
    }

    private func loadMorePosts(mode: AppMode) async {
        guard let query = lastQuery else { return }
        loadGeneration += 1
        let generation = loadGeneration
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let fetched = try await postRepository.searchPosts(query, mode: mode, limit: pageSize, offset: offset)
            guard generation == loadGeneration else { return }
            postResults.append(contentsOf: fetched)
            offset += pageSize
            hasMore = fetched.count == pageSize
        } catch {
            guard generation == loadGeneration else { return }
            hasMore = false
        }
    }

    private func aiPostSearch(prompt: String, mode: AppMode) async {
        guard !prompt.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        error = nil
        resetAIState()
        lastAIPrompt = prompt.trimmingCharacters(in: .whitespaces)
        lastMode = mode
        do {
            let result = try await postRepository.aiSearchPosts(prompt, mode: mode)
            guard generation == loadGeneration else { return }
            postResults = result.posts
            postMatchScores = result.scores
            aiCriteria = result.criteria
            searchWarnings = result.warnings
        } catch {
            guard generation == loadGeneration else { return }
            postResults = []
            postMatchScores = [:]
            aiSearchFailed = true
        }
        if generation == loadGeneration { isLoading = false }
    }

    // MARK: - Private

    /// Clears everything a previous AI search left on screen.
    private func resetAIState() {
        aiCriteria = nil
        searchWarnings = []
        aiSearchFailed = false
        lastAIPrompt = ""
        entitySuggestions = []
        matchEvidence = [:]
        clarifyUnconfirmed = false
        searchSessionId = nil
        fitReasons = [:]
    }

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
        offset = 0
        lastQuery = query
        do {
            let users = try await repository.fetchUsers(mode: mode, search: query, limit: pageSize, offset: 0)
            guard generation == loadGeneration else { return }
            results = excluding(users)
            offset = pageSize
            hasMore = users.count == pageSize
        } catch {
            guard generation == loadGeneration else { return }
            if !(error is CancellationError) {
                results = []
                hasMore = false
                self.error = error.localizedDescription
            }
        }
        if generation == loadGeneration { isLoading = false }
    }
}

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
    var entitySuggestions: [EntitySuggestionDTO] = []   // "ý bạn là …?" vùng xám
    var matchEvidence: [String: [MatchEvidenceDTO]] = [:]   // userId → lý do khớp (mini CV)

    var currentUserId: String? = nil

    private let repository = UserRepository()
    private var searchTask: Task<Void, Never>?
    /// Tăng mỗi lần bắt đầu load mới — response về trễ của lần load cũ
    /// (vd. đổi mode liên tiếp) bị bỏ, không ghi đè kết quả mới hơn
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
        aiReasoning = ""
        aiCriteria = nil
        aiTips = ""
        aiSearchFailed = false
        lastAIPrompt = ""   // browse list, không phải kết quả AI — thoát hẳn AI state
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
            // Không giữ list cũ — có thể là data của mode khác, gây hiển thị sai mode
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
        aiReasoning = ""
        aiCriteria = nil
        aiTips = ""
        aiSearchFailed = false
        entitySuggestions = []
        matchEvidence = [:]
        lastAIPrompt = prompt.trimmingCharacters(in: .whitespaces)
        do {
            let result = try await repository.aiSearch(prompt: prompt, mode: mode, radiusKm: radiusKm)
            results           = excluding(result.users)
            aiReasoning       = result.reasoning
            aiCriteria        = result.criteria
            aiTips            = result.tips
            entitySuggestions = result.suggestions
            matchEvidence     = result.evidence
        } catch {
            print("❌ aiSearch failed: \(error)")
            // Không giữ results cũ (từ browse hoặc AI search trước) — nếu không,
            // results.isEmpty ở SearchView vẫn false và trạng thái lỗi/kujiraRetryState
            // không bao giờ hiển thị, user thấy data cũ như thể vẫn khớp.
            results = []
            aiSearchFailed = true
        }
        print("✅ aiSearch done — criteria: \(String(describing: aiCriteria)), tips: '\(aiTips)'")
        isLoading = false
    }

    /// User bấm "đúng rồi" trên một gợi ý → lưu alias, rồi bỏ gợi ý khỏi UI.
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
        aiReasoning = ""
        aiCriteria = nil
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

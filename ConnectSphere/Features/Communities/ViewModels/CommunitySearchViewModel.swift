import Foundation
import Observation

/// Search inside one community: recent searches, suggestions drawn from the
/// community's own posts, and the server-side results.
@MainActor
@Observable
final class CommunitySearchViewModel {
    var query = ""
    private(set) var results: [Post] = []
    private(set) var isSearching = false
    /// True once a search ran for the current query; typing again goes back to suggestions.
    private(set) var showsResults = false
    private(set) var recents: [String]
    private(set) var errorMessage: String?

    private let communityId: String
    private let token: String
    private let repository = CommunityRepository()
    private let suggestionPool: [String]
    private static let maxRecents = 8
    private var generation = 0

    private var recentsKey: String { "communitySearchRecents.\(communityId)" }

    /// `seedPosts` are the posts the community screen already loaded; suggestions
    /// are mined from their text, so nothing extra is fetched.
    init(communityId: String, token: String, seedPosts: [Post]) {
        self.communityId = communityId
        self.token = token
        self.recents = UserDefaults.standard.stringArray(forKey: "communitySearchRecents.\(communityId)") ?? []
        self.suggestionPool = Self.topTerms(from: seedPosts.map(\.content), limit: 40)
    }

    var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Terms that continue what's being typed; with nothing typed, the most common ones.
    var suggestions: [String] {
        let typed = trimmedQuery.lowercased()
        guard !typed.isEmpty else { return Array(suggestionPool.prefix(8)) }
        return suggestionPool.filter { $0.hasPrefix(typed) && $0 != typed }.prefix(8).map { $0 }
    }

    func queryChanged() {
        // Editing a submitted query returns to suggestions.
        if showsResults { showsResults = false }
    }

    func submit() async {
        let text = trimmedQuery
        guard !text.isEmpty else { return }
        remember(text)
        generation += 1
        let mine = generation
        showsResults = true
        isSearching = true
        errorMessage = nil
        do {
            let found = try await repository.fetchPosts(
                communityId: communityId, search: text, limit: 20, offset: 0, token: token)
            guard mine == generation else { return }
            results = found
        } catch {
            guard mine == generation else { return }
            results = []
            errorMessage = friendlyError(error)
        }
        if mine == generation { isSearching = false }
    }

    func pick(_ term: String) async {
        query = term
        await submit()
    }

    func removeResult(id: String) { results.removeAll { $0.id == id } }

    func forget(_ term: String) {
        recents.removeAll { $0 == term }
        UserDefaults.standard.set(recents, forKey: recentsKey)
    }

    func clearRecents() {
        recents = []
        UserDefaults.standard.removeObject(forKey: recentsKey)
    }

    private func remember(_ text: String) {
        recents.removeAll { $0.caseInsensitiveCompare(text) == .orderedSame }
        recents.insert(text, at: 0)
        recents = Array(recents.prefix(Self.maxRecents))
        UserDefaults.standard.set(recents, forKey: recentsKey)
    }

    // MARK: Suggestion mining

    /// Common words across `texts`, most frequent first. Short words and
    /// filler words in English and Vietnamese are skipped.
    nonisolated static func topTerms(from texts: [String], limit: Int) -> [String] {
        var counts: [String: Int] = [:]
        for text in texts {
            var seen = Set<String>()
            for raw in text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "#" }) {
                let word = raw.hasPrefix("#") ? String(raw.dropFirst()) : String(raw)
                guard word.count >= 3, !stopWords.contains(word), !word.allSatisfy(\.isNumber) else { continue }
                // Once per post, so one long post can't dominate.
                if seen.insert(word).inserted { counts[word, default: 0] += 1 }
            }
        }
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(limit).map(\.key)
    }

    private nonisolated static let stopWords: Set<String> = [
        "the", "and", "for", "are", "but", "not", "you", "all", "any", "can", "had", "her", "was", "one", "our",
        "out", "has", "have", "his", "how", "its", "may", "new", "now", "old", "see", "two", "who", "did", "get",
        "this", "that", "with", "from", "they", "will", "your", "what", "when", "were", "been", "than", "then",
        "them", "into", "just", "like", "some", "very", "about", "would", "there", "their", "which", "could",
        "của", "và", "là", "có", "không", "cho", "các", "một", "những", "được", "trong", "với", "này", "đã",
        "khi", "cũng", "nhưng", "như", "để", "mình", "bạn", "em", "anh", "chị", "ơi", "nha", "nhé", "rồi",
        "thì", "mà", "ở", "tôi", "cái", "nào", "gì", "thế", "vậy", "nữa", "quá", "lắm", "đây", "đó",
    ]
}

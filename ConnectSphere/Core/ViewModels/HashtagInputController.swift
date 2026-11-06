import Foundation
import Observation

/// Owns the text-entry/suggestion state for `HashtagInputView` (typed-but-not-yet-
/// committed text, the debounced suggestion fetch, and the actual chip-commit logic)
/// so the PARENT view (`CreatePostView`) can reach in and
/// flush whatever's still sitting in the text field via `commitPending(into:)` right
/// before reading its `hashtags` array at submit time. Without this, a hashtag typed
/// but never followed by space/return/a suggestion tap was silently dropped.
@Observable
final class HashtagInputController {
    var currentText = ""
    var suggestions: [TagSuggestionDTO] = []
    private var suggestTask: Task<Void, Never>? = nil

    private let repository = PostRepository()
    let maxHashtags = 10
    private let maxTagLength = 100

    /// The token currently being typed, with every "#" stripped (not just the leading one),
    /// used for the suggestion query. Must match EXACTLY how `commit(_:hashtags:)` strips "#"
    /// (also strips it anywhere in the string), otherwise the suggestion query and the token
    /// actually stored would diverge when the user types "#" mid-string (e.g. "#wo#rd").
    var strippedToken: String {
        currentText.replacingOccurrences(of: "#", with: "")
    }

    // MARK: - Text handling

    /// Space/return between tokens → commit each finished token, keeping whatever's
    /// still incomplete (if any) in the text field for the user to keep typing.
    func handleTextChange(_ newValue: String, hashtags: inout [String]) {
        guard newValue.contains(" ") else {
            scheduleSuggestionFetch()
            return
        }
        let endsWithSpace = newValue.hasSuffix(" ")
        var tokens = newValue.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        var remainder = ""
        if !endsWithSpace, let last = tokens.popLast() {
            remainder = last
        }
        for token in tokens {
            _ = commit(token, hashtags: &hashtags)
        }
        // Re-assigning currentText fires onChange again with the remainder (no more
        // whitespace) → naturally falls into the guard branch above, scheduling a new suggestion fetch.
        currentText = remainder
    }

    func commitCurrentText(hashtags: inout [String]) {
        guard commit(currentText, hashtags: &hashtags) else { return }
        currentText = ""
        suggestions = []
        suggestTask?.cancel()
    }

    func selectSuggestion(_ suggestion: TagSuggestionDTO, hashtags: inout [String]) {
        _ = commit(suggestion.tag, hashtags: &hashtags)
        currentText = ""
        suggestions = []
        suggestTask?.cancel()
    }

    /// Commits whatever text is still sitting uncommitted in the field (typed but
    /// never followed by space/return/a suggestion tap) into `hashtags`. Call this
    /// right before reading `hashtags` at submit time so the last hashtag typed
    /// isn't silently dropped. A no-op if the field is already empty.
    func commitPending(into hashtags: inout [String]) {
        guard !currentText.isEmpty else { return }
        commitCurrentText(hashtags: &hashtags)
    }

    /// Validates + appends 1 hashtag. Strips "#" (even if accidentally typed mid-string), strips
    /// any internal whitespace (a safety net. Theoretically can't happen since a space already
    /// commits the previous token), truncates to maxTagLength, and blocks duplicates (case-
    /// insensitive) as well as exceeding the maxHashtags cap.
    @discardableResult
    private func commit(_ raw: String, hashtags: inout [String]) -> Bool {
        var token = raw.replacingOccurrences(of: "#", with: "")
        token = token.components(separatedBy: .whitespacesAndNewlines).joined()
        guard !token.isEmpty else { return false }
        guard hashtags.count < maxHashtags else { return false }
        if token.count > maxTagLength { token = String(token.prefix(maxTagLength)) }
        guard !hashtags.contains(where: { $0.caseInsensitiveCompare(token) == .orderedSame }) else { return false }
        hashtags.append(token)
        return true
    }

    // MARK: - Suggestions fetch (debounced, mirrors SearchViewModel.search)

    private func scheduleSuggestionFetch() {
        suggestTask?.cancel()
        let prefix = strippedToken
        guard !prefix.isEmpty else {
            suggestions = []
            return
        }
        suggestTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            let result = (try? await repository.suggestTags(prefix: prefix, limit: 8)) ?? []
            guard !Task.isCancelled else { return }
            suggestions = result
        }
    }
}

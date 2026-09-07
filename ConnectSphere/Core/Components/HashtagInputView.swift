import SwiftUI

/// Owns the text-entry/suggestion state for `HashtagInputView` (typed-but-not-yet-
/// committed text, the debounced suggestion fetch, and the actual chip-commit logic)
/// so the PARENT view (`CreatePostView`/`CommunityCreatePostView`) can reach in and
/// flush whatever's still sitting in the text field via `commitPending(into:)` right
/// before reading its `hashtags` array at submit time — without this, a hashtag typed
/// but never followed by space/return/a suggestion tap was silently dropped.
@Observable
final class HashtagInputController {
    var currentText = ""
    var suggestions: [TagSuggestionDTO] = []
    private var suggestTask: Task<Void, Never>? = nil

    private let repository = PostRepository()
    let maxHashtags = 10
    private let maxTagLength = 100

    /// The token currently being typed, with every "#" stripped (not just the leading one) —
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
    /// any internal whitespace (a safety net — theoretically can't happen since a space already
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

/// Chip/token hashtag input, shared between Feed's `CreatePostView` and
/// Communities' post composer — bind `hashtags` to whatever `[String]` state the
/// caller submits alongside its create-post request, and own a `HashtagInputController`
/// instance to pass in (call `controller.commitPending(into: &hashtags)` right before
/// reading `hashtags` at submit time — see that method's doc comment).
///
/// User types "#word" then Space/Return to commit it as a chip; a leading "#" is
/// stripped before storage/API calls (chips re-add "#" for display only). While the
/// field is focused with a non-empty token, a debounced (~300ms, mirroring
/// `SearchViewModel`'s search debounce) call to `GET /tags/suggest?prefix=` shows a
/// tappable dropdown of existing matching hashtags. Client-side caps mirror the DB:
/// max 10 hashtags, each ≤100 chars, no embedded whitespace or "#" within one tag.
struct HashtagInputView: View {
    @Environment(\.appBundle) var bundle
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.colorScheme) var colorScheme

    @Binding var hashtags: [String]
    @Bindable var controller: HashtagInputController

    @FocusState private var isFocused: Bool

    private var strippedToken: String { controller.strippedToken }
    private var capReached: Bool { hashtags.count >= controller.maxHashtags }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !hashtags.isEmpty {
                chipsRow
            }

            if capReached {
                Text(String(format: bundle.loc("Maximum of %d hashtags reached"), controller.maxHashtags))
                    .font(.system(size: 12))
                    .foregroundColor(AppColors.textTertiary(colorScheme))
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    TextField(bundle.loc("Add a hashtag (#topic)"), text: $controller.currentText)
                        .font(.system(size: 15))
                        .foregroundColor(AppColors.textPrimary(colorScheme))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        .focused($isFocused)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(AppColors.surface(colorScheme))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(AppColors.borderDefault(colorScheme), lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .onChange(of: controller.currentText) { _, newValue in
                            controller.handleTextChange(newValue, hashtags: &hashtags)
                        }
                        .onSubmit {
                            controller.commitCurrentText(hashtags: &hashtags)
                        }

                    if isFocused && !strippedToken.isEmpty && !controller.suggestions.isEmpty {
                        suggestionsList
                    }
                }
            }
        }
    }

    // MARK: - Chips

    private var chipsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(hashtags, id: \.self) { tag in
                    chip(for: tag)
                }
            }
        }
    }

    private func chip(for tag: String) -> some View {
        HStack(spacing: 4) {
            Text("#\(tag)")
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
            Button {
                hashtags.removeAll { $0 == tag }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13))
            }
            .buttonStyle(.plain)
        }
        .foregroundColor(themeManager.theme.primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(themeManager.theme.primary.opacity(0.1)))
    }

    // MARK: - Suggestions dropdown

    private var suggestionsList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(controller.suggestions, id: \.tag) { suggestion in
                Button {
                    controller.selectSuggestion(suggestion, hashtags: &hashtags)
                } label: {
                    HStack {
                        Text("#\(suggestion.tag)")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(AppColors.textPrimary(colorScheme))
                        Spacer()
                        Text("\(suggestion.usageCount)")
                            .font(.system(size: 12))
                            .foregroundColor(AppColors.textTertiary(colorScheme))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if suggestion.tag != controller.suggestions.last?.tag {
                    Divider().padding(.leading, 12)
                }
            }
        }
        .background(AppColors.elevated(colorScheme))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .padding(.top, 6)
    }
}

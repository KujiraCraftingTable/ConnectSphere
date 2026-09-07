import Foundation

/// What the matcher resolved an input to, plus how much of the input the
/// matched phrase actually accounted for.
///
/// The confidence flag exists because a phrase can match legitimately while
/// still being incidental to the sentence: "my work profile picture is wrong"
/// genuinely contains the token run "work profile", but the user is not asking
/// to switch app modes. Rather than guess, the view model turns a
/// low-confidence match on an instantly-executed action into a confirmation
/// prompt.
struct AssistantMatch: Equatable {
    let intent: AssistantIntent
    let isConfident: Bool

    static let unknown = AssistantMatch(intent: .unknown, isConfident: true)
}

/// Pure, synchronous, dependency-free rule-based matcher — resolves free-text
/// input to an `AssistantIntent` against `AssistantCommandRegistry`, with no
/// network call and no reference to `AppState` (execution happens elsewhere,
/// in `AssistantViewModel`). This is what guarantees the sub-3-second bar
/// trivially: there is no I/O in the loop at all.
enum AssistantMatcher {
    /// Below this share of the input's tokens, a matched phrase is treated as
    /// incidental rather than the point of the sentence. Only gates
    /// instantly-executed intents — guidance replies are just text, so a weak
    /// match there costs nothing worse than an unhelpful answer.
    private static let confidentCoverageRatio = 0.5

    /// Negation cues that make an instantly-executed match untrustworthy —
    /// token matching still has no notion of "reject this," so "I don't want
    /// dark mode, keep it light" would otherwise match and execute
    /// `setTheme(.dark)`. Only cues appearing *before* the matched phrase
    /// count, so "switch to dark mode, don't ask again" still works.
    private static let negationCues = [
        "don't", "dont", "do not", "never mind", "not turn", "not switch",
        "stop using", "turn off", "no longer", "instead of",
        "không muốn", "đừng", "chưa muốn", "tắt", "bỏ",
    ]

    /// Characters that separate words. Splitting on these rather than testing
    /// raw substring containment is what stops a phrase bleeding across word
    /// boundaries — "reset it" no longer matches inside unrelated text.
    private static let separators = CharacterSet.whitespacesAndNewlines
        .union(.punctuationCharacters)
        .union(.symbols)

    /// Resolves `input` to the intent whose registry phrase matches the longest
    /// run of input tokens (longest/most-specific phrase wins). Returns
    /// `.unknown` when no registry phrase appears as a contiguous run in the
    /// input, or when an instantly-executed match is preceded by a negation
    /// cue.
    ///
    /// There is no separate minimum-length floor: `contains` below requires
    /// the *entire* curated phrase to appear, so match strength already equals
    /// however many tokens the registry author chose for that phrase — a
    /// one-token phrase like "logout" is a deliberate, curated command, not a
    /// stray word slipping through.
    static func match(_ input: String) -> AssistantMatch {
        let normalized = input.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return .unknown }

        let inputTokens = tokenize(normalized)
        guard !inputTokens.isEmpty else { return .unknown }

        var bestIntent: AssistantIntent = .unknown
        var bestTokenCount = 0
        var bestCharCount = 0
        var bestPhrase: [String] = []

        for command in AssistantCommandRegistry.all {
            for phrase in command.phrases {
                let phraseTokens = tokenize(phrase)
                guard !phraseTokens.isEmpty else { continue }

                // Longest phrase wins; ties broken by character length so
                // "switch to dark" beats an equally-long-in-tokens vaguer hit.
                let charCount = phrase.count
                let isBetter = phraseTokens.count > bestTokenCount
                    || (phraseTokens.count == bestTokenCount && charCount > bestCharCount)
                guard isBetter, contains(inputTokens, phraseTokens) else { continue }

                bestTokenCount = phraseTokens.count
                bestCharCount  = charCount
                bestIntent     = command.intent
                bestPhrase     = phraseTokens
            }
        }

        guard bestTokenCount > 0 else { return .unknown }

        if bestIntent.isInstantlyExecuted, isNegated(inputTokens, phrase: bestPhrase) {
            return .unknown
        }

        // A phrase that accounts for most of what was typed is a command; one
        // buried in a longer sentence is probably incidental.
        let coverage = Double(bestTokenCount) / Double(inputTokens.count)
        let isConfident = !bestIntent.isInstantlyExecuted || coverage >= confidentCoverageRatio

        return AssistantMatch(intent: bestIntent, isConfident: isConfident)
    }

    // MARK: - Private

    /// Splits on whitespace, punctuation and symbols, dropping empties.
    /// Vietnamese is space-separated per syllable, so this serves both
    /// languages without any language-specific handling.
    private static func tokenize(_ text: String) -> [String] {
        text.components(separatedBy: separators).filter { !$0.isEmpty }
    }

    /// True when `phrase` appears as a contiguous run inside `tokens`.
    private static func contains(_ tokens: [String], _ phrase: [String]) -> Bool {
        indexOf(tokens, phrase) != nil
    }

    /// Start index of `phrase` within `tokens`, or nil.
    private static func indexOf(_ tokens: [String], _ phrase: [String]) -> Int? {
        guard !phrase.isEmpty, tokens.count >= phrase.count else { return nil }
        for start in 0...(tokens.count - phrase.count) {
            if Array(tokens[start..<(start + phrase.count)]) == phrase { return start }
        }
        return nil
    }

    /// True when a negation cue appears *before* the matched phrase. Position
    /// matters: "don't switch to dark mode" rejects, while "switch to dark
    /// mode, don't ask again" does not.
    private static func isNegated(_ tokens: [String], phrase: [String]) -> Bool {
        guard let phraseStart = indexOf(tokens, phrase) else { return false }
        let preceding = Array(tokens[0..<phraseStart])
        guard !preceding.isEmpty else { return false }

        return negationCues.contains { cue in
            let cueTokens = tokenize(cue)
            return !cueTokens.isEmpty && contains(preceding, cueTokens)
        }
    }
}

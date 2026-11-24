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

/// Pure, synchronous, dependency-free rule-based matcher. Resolves free-text
/// input to an `AssistantIntent` against `AssistantCommandRegistry`, with no
/// network call and no reference to `AppState` (execution happens elsewhere,
/// in `AssistantViewModel`).
///
/// Before comparing, input and phrases are reduced the same way: lowercased,
/// filler words dropped ("where is my", "làm sao", "của tôi") and accents
/// folded, so "where are my drafts", "doi mat khau" and "đổi mật khẩu của tôi"
/// all reach their topic. A word of 5+ letters may also be one typo off
/// ("pasword"), but an exact phrase always outranks a fuzzy one.
enum AssistantMatcher {
    /// Below this share of the input's tokens, a matched phrase is treated as
    /// incidental rather than the point of the sentence. Only gates
    /// instantly-executed intents, guidance replies are just text, so a weak
    /// match there costs nothing worse than an unhelpful answer.
    private static let confidentCoverageRatio = 0.5

    /// Negation cues that make an instantly-executed match untrustworthy, so
    /// "I don't want dark mode, keep it light" doesn't switch to dark. Checked
    /// on the words as typed, before folding: folded, "đừng" (don't) would
    /// read as "dùng" (use).
    private static let negationCues = [
        "don't", "dont", "do not", "never mind", "not turn", "not switch",
        "stop using", "turn off", "no longer", "instead of",
        "không muốn", "đừng", "chưa muốn", "tắt", "bỏ",
    ]

    /// Words that carry no meaning for matching: question frames, pronouns,
    /// articles. Dropped from input and phrases alike, as typed (with
    /// accents), because some fold onto real words ("tôi" me → "toi", like
    /// "tối" dark).
    private static let fillerWords: Set<String> = [
        "where", "is", "are", "how", "do", "does", "can", "could", "what", "which",
        "i", "me", "my", "the", "a", "an", "to", "please", "of", "your", "you", "for",
        "tôi", "mình", "của", "giúp", "hãy", "muốn", "ở", "đâu", "sao", "thế", "nào", "cách",
    ]

    /// Words too common to suggest a topic on their own when nothing matched.
    private static let genericWords: Set<String> = [
        "change", "turn", "open", "go", "show", "set", "update", "edit", "off", "on",
        "settings", "setting", "mode", "make", "add", "remove", "manage", "get",
        "something", "anything", "thing", "things", "stuff", "about", "with", "and",
        "doi", "thay", "mo", "bat", "tat", "cai", "dat", "che", "do",
    ]

    /// Characters that separate words. Splitting on these rather than testing
    /// raw substring containment is what stops a phrase bleeding across word
    /// boundaries, "reset it" no longer matches inside unrelated text.
    private static let separators = CharacterSet.whitespacesAndNewlines
        .union(.punctuationCharacters)
        .union(.symbols)
        .subtracting(CharacterSet(charactersIn: "'"))

    /// Every registry phrase, reduced once.
    private static let entries: [(intent: AssistantIntent, tokens: [String], chars: Int)] =
        AssistantCommandRegistry.all.flatMap { command in
            command.phrases.map { (command.intent, reduce($0), $0.count) }
        }

    /// Resolves `input` to the intent whose phrase covers the longest run of
    /// input words. Ties go to the phrase with more exact (not typo-matched)
    /// words, then the longer phrase. Returns `.unknown` when no phrase
    /// appears, or when an instantly-executed match follows a negation cue.
    static func match(_ input: String) -> AssistantMatch {
        let indexed = reduceIndexed(input)
        let words = indexed.map(\.word)
        guard !words.isEmpty else { return .unknown }

        var best: (intent: AssistantIntent, length: Int, exact: Int, chars: Int, start: Int)?
        for entry in entries where !entry.tokens.isEmpty {
            guard let found = find(entry.tokens, in: words) else { continue }
            let isBetter = best.map {
                (entry.tokens.count, found.exact, entry.chars) > ($0.length, $0.exact, $0.chars)
            } ?? true
            if isBetter { best = (entry.intent, entry.tokens.count, found.exact, entry.chars, found.start) }
        }
        guard let best else { return .unknown }

        if best.intent.isInstantlyExecuted, isNegated(input, beforeRawIndex: indexed[best.start].raw) {
            return .unknown
        }

        // A phrase that accounts for most of what was typed is a command; one
        // buried in a longer sentence is probably incidental. Half isn't
        // enough: "my work profile picture is wrong" is half "work profile".
        let coverage = Double(best.length) / Double(words.count)
        let isConfident = !best.intent.isInstantlyExecuted || coverage > confidentCoverageRatio
        return AssistantMatch(intent: best.intent, isConfident: isConfident)
    }

    /// Up to `limit` guidance topics sharing a meaningful word with `input`,
    /// best first, for when nothing matched outright. Empty when no word is
    /// shared.
    static func closestTopics(_ input: String, limit: Int = 3) -> [AssistantGuidanceTopic] {
        let words = reduce(input).filter { !genericWords.contains($0) }
        guard !words.isEmpty else { return [] }
        let scored: [(topic: AssistantGuidanceTopic, score: Int)] = AssistantGuidanceTopic.allCases.compactMap { topic in
            let score = topic.phrases.map { phrase in
                Set(reduce(phrase)).filter { token in words.contains { sameWord($0, token) } }.count
            }.max() ?? 0
            return score > 0 ? (topic, score) : nil
        }
        // Stable: equal scores keep catalogue order.
        return scored.enumerated()
            .sorted { ($0.element.score, -$0.offset) > ($1.element.score, -$1.offset) }
            .prefix(limit)
            .map(\.element.topic)
    }

    /// The words that matter, in order: lowercased, split, filler and stray
    /// single letters dropped (a "m" typed for "my"), accents folded.
    static func reduce(_ text: String) -> [String] {
        reduceIndexed(text).map(\.word)
    }

    /// `reduce`, keeping each word's position among the raw words, so a
    /// match can be traced back to what was typed before it.
    private static func reduceIndexed(_ text: String) -> [(word: String, raw: Int)] {
        rawWords(text).enumerated()
            .filter { !fillerWords.contains($0.element) && !($0.element.count == 1 && $0.element.first!.isLetter) }
            .map { (fold($0.element), $0.offset) }
    }

    private static func rawWords(_ text: String) -> [String] {
        text.lowercased().components(separatedBy: separators).filter { !$0.isEmpty }
    }

    /// Case- and accent-free, with đ read as d, so typing without Vietnamese
    /// accents still matches.
    static func fold(_ word: String) -> String {
        word.replacingOccurrences(of: "đ", with: "d")
            .folding(options: .diacriticInsensitive, locale: nil)
    }

    // MARK: - Private

    /// Where `phrase` appears as a contiguous run in `words`: the start of
    /// the run with the most exactly-matched words; nil when it doesn't appear.
    private static func find(_ phrase: [String], in words: [String]) -> (start: Int, exact: Int)? {
        guard words.count >= phrase.count else { return nil }
        var best: (start: Int, exact: Int)?
        for start in 0...(words.count - phrase.count) {
            var exact = 0
            var matched = true
            for (offset, token) in phrase.enumerated() {
                let word = words[start + offset]
                if word == token { exact += 1 } else if !sameWord(word, token) { matched = false; break }
            }
            if matched, exact > (best?.exact ?? -1) { best = (start, exact) }
        }
        return best
    }

    /// Equal, or one typo apart: both 5+ letters, same first letter, and one
    /// letter added, missing, changed or swapped with its neighbour. The first
    /// letter has to agree so "light" never reads as "night".
    private static func sameWord(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        guard a.count >= 5, b.count >= 5, a.first == b.first, abs(a.count - b.count) <= 1 else { return false }
        return editDistance(Array(a), Array(b)) <= 1
    }

    /// Optimal string alignment distance (Levenshtein plus adjacent swaps).
    private static func editDistance(_ a: [Character], _ b: [Character]) -> Int {
        var d = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 0...a.count { d[i][0] = i }
        for j in 0...b.count { d[0][j] = j }
        for i in 1...max(a.count, 1) where i <= a.count {
            for j in 1...max(b.count, 1) where j <= b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    d[i][j] = min(d[i][j], d[i - 2][j - 2] + 1)
                }
            }
        }
        return d[a.count][b.count]
    }

    /// True when a negation cue appears among the raw words typed before
    /// the matched phrase. "don't switch to dark mode" rejects, "switch to
    /// dark mode, don't ask again" does not.
    private static func isNegated(_ input: String, beforeRawIndex start: Int) -> Bool {
        let preceding = Array(rawWords(input).prefix(start))
        guard !preceding.isEmpty else { return false }
        return negationCues.contains { cue in
            let cueWords = rawWords(cue)
            guard !cueWords.isEmpty, preceding.count >= cueWords.count else { return false }
            return (0...(preceding.count - cueWords.count)).contains {
                Array(preceding[$0..<($0 + cueWords.count)]) == cueWords
            }
        }
    }
}

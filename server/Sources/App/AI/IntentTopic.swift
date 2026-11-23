/// The topic left in the LLM's English restatement of a prompt once the
/// search wording is gone: "find people interested in beekeeping" →
/// "beekeeping". Used when the LLM's reading names no topic at all: a hobby
/// that isn't in the catalogue (beekeeping) has no alias to fall back on,
/// and a sampled reading has dropped it while restating it correctly.
enum IntentTopic {
    static let searchWords: Set<String> = [
        "find", "finding", "search", "searching", "look", "looking", "for", "meet", "connect",
        "who", "whom", "that", "which", "are", "is", "am", "be", "into", "interested", "in",
        "love", "loves", "like", "likes", "enjoy", "enjoys", "want", "wants", "also", "really",
        "the", "a", "an", "to", "and", "with", "of", "about", "me", "my", "i", "some", "other",
        "others", "new", "anyone",
    ]

    /// At most this many words: more than that is a sentence, not a topic.
    static let maxWords = 5

    static func topic(in intent: String) -> String? {
        let words = intent.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "-" })
            .map(String.init)
            .filter { !searchWords.contains($0) && !SearchConcepts.personWords.contains($0) }
        guard !words.isEmpty, words.count <= maxWords,
              words.joined().filter(\.isLetter).count >= 3 else { return nil }
        return words.joined(separator: " ")
    }

    static func concept(in intent: String) -> SearchConcepts.Concept? {
        topic(in: intent).map { SearchConcepts.Concept(label: $0, terms: [$0], declared: [$0], vectorText: $0) }
    }
}

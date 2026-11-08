import Foundation

/// Instant, free word rules for Vietnamese and English text — the first of the
/// automatic checks (the second is the local AI, `LocalGuard`). Two outcomes:
/// `block` (slurs, threats, child sexual exploitation: refused outright) and
/// `nudge` (profanity and insults: the app asks "Are you sure you want to post
/// this?", as Instagram does, and sends it if the person insists).
///
/// Vietnamese is typed with and without accents, so a word is matched in two
/// forms. Rude words that stay rude with accents stripped are matched in the
/// folded form; words that would collide with ordinary ones once folded (`cặc`
/// vs `các` "the", `lợn` "pig" vs `lồn`) are matched with their accents only.
enum ModerationRules {
    enum Verdict: Equatable { case clean, nudge, block(ModerationPolicy) }

    // MARK: lists

    /// Matched against the folded text (accents and `đ` stripped, look-alike
    /// digits mapped back) — only words with no ordinary folded twin.
    private static let severeFolded: [String: ModerationPolicy] = [
        "nigger": .hate, "faggot": .hate, "tranny": .hate,
        "kill yourself": .harassment, "go kill yourself": .harassment,
        "i will kill you": .violence, "i ll kill you": .violence, "ill kill you": .violence,
        "tao giet may": .violence, "tao se giet may": .violence, "giet chet may": .violence,
        "dam chet may": .violence, "tao se dam chet may": .violence,
        "child porn": .childSafety, "kiddie porn": .childSafety, "loli": .childSafety, "lolicon": .childSafety,
    ]

    /// Accents kept: folded they'd match ordinary words ("ấu dâm" vs "âu đảm").
    private static let severeAccented: [String: ModerationPolicy] = [
        "ấu dâm": .childSafety, "khiêu dâm trẻ em": .childSafety,
    ]

    private static let profanityFolded: Set<String> = [
        "dit me", "dit con me", "du ma", "du me", "dcm", "dmm", "cmm", "cmn", "vcl", "vkl", "clgt", "djt", "dkm",
        "dcmm", "ngu vcl", "thang ngu", "khon nan",
        "fuck", "fucking", "fucker", "motherfucker", "shit", "bullshit", "bitch", "cunt", "dick", "pussy",
        "asshole", "bastard", "slut", "whore", "retard", "nigga", "wtf", "stfu",
    ]

    /// Accents kept: these fold into ordinary words (`các`, `lợn`, `đủ`, `dẻo`).
    private static let profanityAccented: Set<String> = [
        "địt", "đụ", "lồn", "cặc", "buồi", "đéo", "đĩ", "đm", "đcm", "đmm", "đjt", "đkm",
        "đồ ngu", "đồ rác", "óc chó", "mất dạy", "cút đi", "đi chết đi", "chết mẹ mày", "con đĩ", "thằng chó", "đồ chó",
    ]

    /// Only for the interest and skill pickers, which are stricter than chat:
    /// adult and drug words that are fine in a news post or a conversation.
    private static let interestOnlyWords: Set<String> = [
        "dm", "sex", "porn", "porno", "nude", "nudes", "hentai", "xxx", "nsfw", "onlyfans",
        "cocaine", "heroin", "meth", "ketamine", "mdma", "ecstasy",
    ]
    private static let interestOnlyPhrases: [String] = [
        "ma túy", "ma tuý", "thuốc lắc", "cần sa", "hàng trắng", "phim sex", "làm tình",
    ]

    // MARK: normalising

    struct Normalized {
        /// Lowercase, accents kept, runs of repeated letters collapsed.
        let accented: [String]
        /// Accents and `đ` stripped, digits that stand in for letters mapped back.
        let folded: [String]
        var accentedPhrase: String { " " + accented.joined(separator: " ") + " " }
        var foldedPhrase: String { " " + folded.joined(separator: " ") + " " }
    }

    static func normalize(_ text: String) -> Normalized {
        let lowered = collapseRepeats(text.lowercased().precomposedStringWithCanonicalMapping)
        var accented = lowered.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        // "đ.m" and "f u c k": a run of single letters is one word.
        accented += joinedSingles(accented)
        let folded = accented.map(fold)
        return Normalized(accented: accented, folded: folded)
    }

    private static func fold(_ token: String) -> String {
        var t = token.replacingOccurrences(of: "đ", with: "d")
            .folding(options: [.diacriticInsensitive], locale: Locale(identifier: "en"))
        // "f4ck", "sh1t": digits stand in for letters only inside a word.
        if t.count >= 3, t.contains(where: \.isLetter) {
            let map: [Character: Character] = ["0": "o", "1": "i", "3": "e", "4": "a", "5": "s", "7": "t"]
            t = String(t.map { map[$0] ?? $0 })
        }
        return t
    }

    /// "fuuuuck" → "fuck": three or more of a letter become one.
    private static func collapseRepeats(_ s: String) -> String {
        var out = ""
        var last: Character?
        var run = 0
        for ch in s {
            if ch == last { run += 1 } else { last = ch; run = 1 }
            if run < 3 { out.append(ch) } else if run == 3 { out.removeLast() }
        }
        return out
    }

    private static func joinedSingles(_ tokens: [String]) -> [String] {
        var joined: [String] = []
        var run = ""
        func flush() { if run.count >= 2 { joined.append(run) }; run = "" }
        for t in tokens {
            if t.count == 1, t.first!.isLetter { run += t } else { flush() }
        }
        flush()
        return joined
    }

    // MARK: verdicts

    static func verdict(_ text: String) -> Verdict {
        let n = normalize(text)
        let phrase = n.foldedPhrase
        for (needle, policy) in severeFolded where phrase.contains(" \(needle) ") { return .block(policy) }
        let aPhrase = n.accentedPhrase
        for (needle, policy) in severeAccented where aPhrase.contains(" \(needle) ") { return .block(policy) }
        if n.folded.contains(where: profanityFolded.contains)
            || profanityFolded.contains(where: { $0.contains(" ") && phrase.contains(" \($0) ") }) { return .nudge }
        if n.accented.contains(where: profanityAccented.contains)
            || profanityAccented.contains(where: { $0.contains(" ") && aPhrase.contains(" \($0) ") }) { return .nudge }
        return .clean
    }

    /// The interest and skill pickers: anything rude, or adult and drug words.
    static func isListedForInterests(_ text: String) -> Bool {
        if verdict(text) != .clean { return true }
        let n = normalize(text)
        let aPhrase = n.accentedPhrase
        return n.accented.contains(where: interestOnlyWords.contains)
            || interestOnlyPhrases.contains { aPhrase.contains(" \($0) ") }
    }

    // MARK: links and scams

    private static let linkPattern = try! NSRegularExpression(
        pattern: #"(?i)(https?://|www\.|\b(?:t\.me|zalo\.me|bit\.ly|tinyurl\.com|wa\.me)/)\S+"#)

    static func containsLink(_ text: String) -> Bool {
        linkPattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static let bankNumber = try! NSRegularExpression(pattern: #"(?<!\d)\d[\d .-]{7,17}\d(?!\d)"#)
    private static let payKeywords = ["chuyen khoan", "ck truoc", "stk", "so tai khoan", "dat coc", "coc truoc", "ung truoc"]
    private static let moneyPromises = ["kiem tien online", "lai suat", "cam ket loi nhuan", "loi nhuan", "viec nhe luong cao",
                                        "hoa hong", "nap tien", "dau tu sinh loi", "lam giau", "tuyen cong tac vien"]

    /// A post or message that reads like the common Vietnamese scams: a bank
    /// account with a payment demand, or get-rich promises together with a link.
    static func looksLikeScam(_ text: String) -> Bool {
        let n = normalize(text)
        let phrase = n.foldedPhrase
        let range = NSRange(text.startIndex..., in: text)
        let hasAccount = bankNumber.firstMatch(in: text, range: range) != nil
        let asksPayment = payKeywords.contains { phrase.contains(" \($0) ") }
        let promises = moneyPromises.filter { phrase.contains(" \($0) ") }.count
        return (hasAccount && asksPayment) || promises >= 2 || (promises >= 1 && containsLink(text))
    }
}

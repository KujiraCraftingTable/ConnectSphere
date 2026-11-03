import Foundation
import SQLKit

/// What a people-search prompt asks for (AI_SEARCH_REVIEW.md, phase S6). The
/// prompt decides who qualifies: every topic it names must be matched, and
/// taste only orders the people who qualify. Read deterministically first —
/// catalogue aliases, traits we don't search by, partner-seeking — so slang
/// and topics the LLM drops ("hút thuốc", "chém gió") still count.
enum SearchConcepts {
    /// One topic the prompt names.
    struct Concept: Equatable {
        /// As typed, for "No one here is into …".
        var label: String
        /// English words for the full-text check over profile and post text.
        var terms: [String]
        /// Lowercased names a declared interest or skill may have.
        var declared: [String]
        /// Embedded on its own for the post-similarity check.
        var vectorText: String
    }

    /// A post at least this close to a topic, embedded on its own, is about
    /// it. Measured: posts about football, anime or photography sit at
    /// 0.65–0.71; the closest unrelated post to any topic tried was 0.62.
    static let conceptPostMin = 0.64

    // MARK: Catalogue aliases

    /// Words of `s`, lowercased, split on anything that isn't a letter or digit.
    static func words(_ s: String) -> [String] {
        s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    struct AliasHit { var entry: InterestStore.Entry; var start: Int; var length: Int; var typed: String }

    /// Every catalogue entry the prompt names, longest match first where two
    /// overlap ("chụp ảnh film" is Film photography, not Movies). Accents must
    /// match, except in aliases of two or more words: "hut thuoc" is clearly
    /// "hút thuốc", but folded single words collide ("có" ↔ "cờ").
    static func aliasHits(_ prompt: String, entries: [InterestStore.Entry]) -> [AliasHit] {
        let typed = words(prompt)
        let folded = typed.map(InterestRules.fold)
        var hits: [AliasHit] = []
        for e in entries {
            for alias in [e.name_en.lowercased()] + e.aliases {
                let a = words(alias)
                guard !a.isEmpty, a.count <= typed.count else { continue }
                let af = a.map(InterestRules.fold)
                for start in 0...(typed.count - a.count) {
                    let exact = Array(typed[start..<start + a.count]) == a
                    let loose = a.count >= 2 && Array(folded[start..<start + a.count]) == af
                    if exact || loose {
                        hits.append(AliasHit(entry: e, start: start, length: a.count,
                                             typed: typed[start..<start + a.count].joined(separator: " ")))
                    }
                }
            }
        }
        var taken = Set<Int>()
        var kept: [AliasHit] = []
        for h in hits.sorted(by: { $0.length != $1.length ? $0.length > $1.length : $0.start < $1.start }) {
            let span = Set(h.start..<h.start + h.length)
            guard taken.isDisjoint(with: span), !kept.contains(where: { $0.entry.id == h.entry.id }) else { continue }
            taken.formUnion(span)
            kept.append(h)
        }
        return kept.sorted { $0.start < $1.start }
    }

    /// The entry and everything under it: a search for Sports includes
    /// Football, but one for Football never includes Sports.
    static func family(of entry: InterestStore.Entry, in entries: [InterestStore.Entry]) -> [InterestStore.Entry] {
        var out = [entry], frontier = [entry.id]
        while !frontier.isEmpty {
            let children = entries.filter { $0.parent_id.map(frontier.contains) ?? false }
            out += children
            frontier = children.map(\.id)
        }
        return out
    }

    static func concept(for entry: InterestStore.Entry, label: String, in entries: [InterestStore.Entry]) -> Concept {
        let fam = family(of: entry, in: entries)
        let english = fam.flatMap { [$0.name_en] + $0.aliases.filter { $0.allSatisfy(\.isASCII) } }
        return Concept(label: label, terms: unique(english), declared: unique(fam.map { $0.name_en.lowercased() }),
                       vectorText: entry.name_en)
    }

    // MARK: Everything the prompt names

    /// Words the LLM sometimes hands back as "bio keywords" that only mean
    /// "a person": they name no topic.
    static let personWords: Set<String> = [
        "friend", "friends", "person", "people", "someone", "somebody", "buddy", "mate", "partner",
        "guy", "girl", "boy", "man", "woman", "male", "female", "bạn", "người", "nam", "nữ",
    ]

    /// The catalogue entries a search reads prompts against: interests for
    /// Hobby, skills too for Work ("reactjs" → React), both when no mode.
    /// Skills take the interest entry's shape so one alias scan serves both.
    static func searchEntries(mode: String?, on db: any SQLDatabase) async throws -> [InterestStore.Entry] {
        let interests = try await InterestStore.entries(on: db)
        guard mode != "hobby" else { return interests }
        let skills = try await SkillStore.entries(on: db).map {
            InterestStore.Entry(id: $0.id, name_en: $0.name_en, name_vi: $0.name_vi, category: $0.category,
                                parent_id: $0.parent_id, aliases: $0.aliases, allows_specific: false,
                                pick_count: $0.pick_count)
        }
        return mode == "work" ? skills + interests : interests + skills
    }

    /// Catalogue topics in the prompt first, then whatever else the LLM pulled
    /// out (entities, interests, skills, roles). A topic named twice counts
    /// once; terms without a letter ("67") name nothing.
    static func concepts(prompt: String, criteria c: OllamaService.SearchCriteria,
                         entries: [InterestStore.Entry]) -> [Concept] {
        var out: [Concept] = []
        var seenEntries = Set<String>()
        func add(_ entry: InterestStore.Entry, label: String) {
            guard seenEntries.insert(entry.id).inserted else { return }
            out.append(concept(for: entry, label: label, in: entries))
        }
        func add(label: String, terms: [String]) {
            let t = unique(terms.map { $0.trimmingCharacters(in: .whitespaces) }.filter(hasLetter))
            guard !t.isEmpty else { return }
            if let e = t.lazy.compactMap({ InterestRules.entry(named: $0, in: entries) }).first {
                return add(e, label: label)
            }
            let lower = t.map { $0.lowercased() }
            guard !out.contains(where: { !Set($0.declared).isDisjoint(with: lower) }) else { return }
            out.append(Concept(label: label, terms: t, declared: lower, vectorText: t.joined(separator: ", ")))
        }

        for hit in aliasHits(prompt, entries: entries) { add(hit.entry, label: hit.typed) }
        if let name = c.entity_name { add(label: name, terms: [name] + c.entity_keywords) }
        for group in c.interest_groups {
            // The entity's own kind ("anime" for Kimetsu no Yaiba) isn't a
            // second topic.
            if let kind = c.entity_type, c.entity_name != nil, group.contains(where: { $0.lowercased() == kind }) { continue }
            if let first = group.first { add(label: first, terms: group) }
        }
        if !c.skills.isEmpty { add(label: c.skills.joined(separator: ", "), terms: c.skills) }
        if !c.job_title_keywords.isEmpty { add(label: c.job_title_keywords.joined(separator: ", "), terms: c.job_title_keywords) }
        let traits = c.bio_keywords.filter { !personWords.contains($0.lowercased()) && !$0.contains(where: \.isNumber) }
        if !traits.isEmpty { add(label: traits.joined(separator: ", "), terms: traits) }
        return out
    }

    // MARK: What normal search doesn't do

    /// Height, weight and looks aren't stored and won't be: "1m8", "cao 1m7",
    /// "50kg", "đẹp trai". Returns the phrase as typed.
    static func unsupportedTrait(_ prompt: String) -> String? {
        firstMatch(unsupportedPattern, in: prompt)
    }
    private static let unsupportedPattern = try! NSRegularExpression(
        pattern: #"\b\d+\s?m\s?\d+\b|\b\d+([.,]\d+)?\s?(cm|kg|m|mét|met|meters?|feet|ft)\b|chiều cao|cân nặng|ngoại hình|đẹp trai|xinh gái|cao ráo|\b(tall|height|weight|handsome|good[- ]looking)\b"#,
        options: [.caseInsensitive])

    /// Looking for a partner rather than a friend or colleague. Dating is its
    /// own space, so normal search answers these with a pointer instead.
    /// Unaccented forms are listed only where they can't be another phrase
    /// ("tim bo" is also "tìm bộ phim").
    static func seeksPartner(_ prompt: String) -> Bool {
        firstMatch(partnerPattern, in: prompt) != nil
    }
    private static let partnerPattern = try! NSRegularExpression(
        pattern: #"người yêu|người iu|người thương|bạn trai|bạn gái|bạn đời|hẹn hò|nửa kia|\bny\b|(tìm|kiếm|có) bồ\b|nguoi yeu|nguoi iu|ban trai|ban gai|hen ho|\b(crush|girlfriend|boyfriend|dating|lover|soulmate)\b|\bsomeone to date\b|\ba date\b"#,
        options: [.caseInsensitive])

    /// Whether the prompt mentions an age, so a bare number ("thích 8") is
    /// never read as one.
    static func mentionsAge(_ prompt: String) -> Bool {
        firstMatch(agePattern, in: prompt) != nil
    }
    private static let agePattern = try! NSRegularExpression(
        pattern: #"tuổi|tuoi|\bage[sd]?\b|years?[- ]old|\byo\b|\b\d+\s?t\b|\b\d0s\b|\b[0-9]x\b|\b2k\d*\b|sinh năm|thế hệ|teen|đời \d"#,
        options: [.caseInsensitive])

    // MARK: helpers

    private static func firstMatch(_ re: NSRegularExpression, in s: String) -> String? {
        guard let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let r = Range(m.range, in: s) else { return nil }
        return String(s[r])
    }
    private static func hasLetter(_ s: String) -> Bool { s.contains(where: \.isLetter) }
    private static func unique(_ xs: [String]) -> [String] {
        var seen = Set<String>()
        return xs.filter { seen.insert($0.lowercased()).inserted }
    }
}

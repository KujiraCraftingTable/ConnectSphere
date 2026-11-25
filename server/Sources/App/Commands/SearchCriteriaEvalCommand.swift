import Vapor

/// `swift run App search-criteria-eval server/Tests/Fixtures/search_criteria_eval.jsonl [--model <m>] [--compare <m>] [--list]`
///
/// Reads a fixed set of search prompts with one or two models, without the
/// cache, and checks each reading names what the prompt asks for: topics,
/// roles, gender, ages and "like me". Places aren't scored: districts, wards
/// and landmarks are read from the prompt text by `PlaceReader`, and the
/// model's `location` only ever holds a province. This is what decides whether
/// `SEARCH_MODEL` can be a smaller, faster model than `OLLAMA_MODEL`. Each
/// line of the file: `{"query", "mode", "expect": {"topics", "roles",
/// "gender", "age_min", "age_max", "like_me"}}`, every `expect` field optional.
struct SearchCriteriaEvalCommand: AsyncCommand {
    struct Signature: CommandSignature {
        @Argument(name: "file", help: "JSON-lines evaluation set.") var file: String
        @Option(name: "model", help: "Model to read with (default: SEARCH_MODEL).") var model: String?
        @Option(name: "compare", help: "A second model, read the same way.") var compare: String?
        @Flag(name: "list", help: "Also list every miss.") var list: Bool
    }

    var help: String { "Scores how well a model reads AI-search prompts against a fixed set." }

    // MARK: - Fixtures and scores
    struct Expect: Decodable {
        var topics: [String]?; var roles: [String]?
        var gender: String?; var age_min: Int?; var age_max: Int?; var like_me: Bool?
    }
    struct Item: Decodable { let query: String; let mode: String; let expect: Expect }

    struct Score {
        var passed = 0, seconds = 0.0
        var checks: [String: (hit: Int, of: Int)] = [:]
        var misses: [(query: String, missing: [String])] = []
        mutating func check(_ field: String, _ ok: Bool) {
            var c = checks[field] ?? (0, 0)
            c.of += 1
            if ok { c.hit += 1 }
            checks[field] = c
        }
    }

    // MARK: - Run
    func run(using context: CommandContext, signature: Signature) async throws {
        let app = context.application
        let console = context.console
        guard let text = try? String(contentsOfFile: signature.file, encoding: .utf8) else {
            console.error("Can't read \(signature.file)"); return
        }
        let items = try text.split(whereSeparator: \.isNewline).map {
            try JSONDecoder().decode(Item.self, from: Data($0.utf8))
        }
        let models = [signature.model ?? app.appEnv.ollama.searchModel] + [signature.compare].compactMap { $0 }
        var scores: [Score] = []
        for model in models {
            console.print("Reading \(items.count) prompts with \(model)…")
            var cfg = app.ollama
            cfg.model = model
            scores.append(await score(items, cfg: cfg, logger: app.logger))
        }
        for (model, s) in zip(models, scores) {
            console.print("\n\(model): \(s.passed)/\(items.count) prompts read in full, "
                          + String(format: "%.1f s", s.seconds / Double(max(items.count, 1))) + " per prompt")
            let fields = ["topics", "roles", "gender", "age", "like me"]
            console.print("  " + fields.compactMap { f in s.checks[f].map { "\(f) \($0.hit)/\($0.of)" } }.joined(separator: ", "))
            if signature.list || models.count == 1 {
                for m in s.misses { console.print("  miss: \"\(m.query)\": \(m.missing.joined(separator: ", "))") }
            }
        }
        if scores.count == 2 {
            let a = Dictionary(uniqueKeysWithValues: scores[0].misses.map { ($0.query, $0.missing) })
            let b = Dictionary(uniqueKeysWithValues: scores[1].misses.map { ($0.query, $0.missing) })
            let onlyB = b.keys.filter { a[$0] == nil }.sorted()
            let onlyA = a.keys.filter { b[$0] == nil }.sorted()
            console.print("\nRead in full by \(models[0]) but not \(models[1]): \(onlyB.count)")
            for q in onlyB { console.print("  \"\(q)\": \(b[q]!.joined(separator: ", "))") }
            console.print("Read in full by \(models[1]) but not \(models[0]): \(onlyA.count)")
            for q in onlyA { console.print("  \"\(q)\": \(a[q]!.joined(separator: ", "))") }
        }
    }

    // MARK: - Scoring
    private func score(_ items: [Item], cfg: OllamaService.Config, logger: Logger) async -> Score {
        var s = Score()
        for item in items {
            let start = Date()
            let (c, _) = await OllamaService.analyzeCriteria(cfg, item.query, mode: item.mode, logger: logger)
            s.seconds += Date().timeIntervalSince(start)
            var missing: [String] = []
            let words = (c.interests + c.skills + c.bio_keywords + c.job_title_keywords + c.entity_keywords
                         + c.interest_groups.flatMap { $0 } + [c.entity_name].compactMap { $0 }).map(Self.fold)
            func has(_ term: String) -> Bool { let t = Self.fold(term); return words.contains { $0.contains(t) } }
            for t in item.expect.topics ?? [] {
                s.check("topics", has(t)); if !has(t) { missing.append("topic \(t)") }
            }
            for r in item.expect.roles ?? [] {
                s.check("roles", has(r)); if !has(r) { missing.append("role \(r)") }
            }
            if let g = item.expect.gender {
                let ok = c.target_gender?.lowercased() == g
                s.check("gender", ok); if !ok { missing.append("gender \(g)") }
            }
            if item.expect.age_min != nil || item.expect.age_max != nil {
                let ok = c.target_age_min == item.expect.age_min && c.target_age_max == item.expect.age_max
                s.check("age", ok); if !ok { missing.append("age \(item.expect.age_min ?? 0)-\(item.expect.age_max ?? 0)") }
            }
            if let likeMe = item.expect.like_me {
                let ok = c.like_me == likeMe
                s.check("like me", ok); if !ok { missing.append("like me") }
            }
            if missing.isEmpty { s.passed += 1 } else { s.misses.append((item.query, missing)) }
        }
        return s
    }

    /// Case and accents don't matter.
    static func fold(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: "đ", with: "d").folding(options: .diacriticInsensitive, locale: nil)
    }
}

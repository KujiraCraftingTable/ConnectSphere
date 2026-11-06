import Vapor
import AsyncHTTPClient
import SQLKit
import NIOFoundationCompat

/// Query understanding,
/// translation, and text embedding via a local Ollama instance.
///
/// `translateToEnglish` **throws** on an Ollama failure (rather than embedding
/// the raw non-English text) so the embedding queue's retry re-runs the
/// translation instead of poisoning the chunk.
enum OllamaService {
    static let keepAlive = "30m"
    static let embedModel = "mxbai-embed-large"

    // MARK: config

    struct Config: Sendable {
        var url: String
        var model: String
        var client: HTTPClient
        init(_ env: AppEnv.Ollama, client: HTTPClient) { url = env.url; model = env.model; self.client = client }
    }

    // MARK: prompts

    static let locationList = #""Ho Chi Minh"|"Hanoi"|"Da Nang"|"Hai Phong"|"Can Tho"|"Hue"|"Tuyen Quang"|"Lao Cai"|"Thai Nguyen"|"Phu Tho"|"Bac Ninh"|"Hung Yen"|"Ninh Binh"|"Quang Tri"|"Quang Ngai"|"Gia Lai"|"Khanh Hoa"|"Lam Dong"|"Dak Lak"|"Dong Nai"|"Tay Ninh"|"Vinh Long"|"Dong Thap"|"Ca Mau"|"An Giang"|"Lai Chau"|"Dien Bien"|"Son La"|"Lang Son"|"Quang Ninh"|"Thanh Hoa"|"Nghe An"|"Ha Tinh"|"Cao Bang""#

    static var analyzerPrompt: String {
        """
        You are a query analyzer for a social network people-search.
        Analyze the search query (any language) and return JSON.

        intent_en: the core search intent translated to English. Preserve proper nouns exactly (anime/movie/song titles, artist names, team names, brands, companies, universities, frameworks, tools, places). Remove greetings, filler ("help me", "I want to"), and emotional noise. Keep only what describes WHO the user wants to find.
        mode: "hobby" if looking for friends or social connections, "work" if looking for work or study partners, null if unclear.
        target_gender: "male" or "female" ONLY when explicitly asked ("bạn nam", "female friend"). Never guess from context.
        target_age_min / target_age_max: ALWAYS set these when the query mentions any age. Never skip them. A bare number without "tuổi" / "years old" ("thích 8", "số 67") is never an age. "20-30" -> min 20, max 30. "over 25"/"trên 25"/"trên 25 tuổi" -> min 25, max null. "under 30"/"dưới 30" -> min null, max 30. A single age ("25 tuổi", "around 25") -> a ±2 range, min 23 max 27. Only omit when no age is mentioned at all.
        entity_type: type of the specific named entity, one of: anime, manga, movie, tv_show, book, game, music, podcast, celebrity, art, food, sport, company, university, industry, programming_language, framework, tool, certification, job_role, professional_field, startup. null if the query names no specific entity.
        entity_name: canonical English name of that entity. null if none.
        interest_groups: 2D array for hobbies/lifestyle. Each inner array is ONE concept plus its synonyms, base-form nouns/verbs only, no adjectives or emotion words. AND between groups, OR within a group. Include every activity, habit or lifestyle asked for, including smoking, drinking or chatting. Never drop one. CORRECT: [["cook","cooking","food"],["travel","hiking"]]. WRONG: [["cook","travel"]], never mix concepts.
        skills: work or study skills only (iOS, React, Python, Accounting, Marketing). Never put these in interest_groups.
        bio_keywords: words describing the person type (student, freelancer, senior, teacher).
        job_title_keywords: job or role titles (developer, designer, accountant).
        location: exact match from this list only, \(locationList), null if not mentioned.
        place_name: a specific venue name when the city is unknown (e.g. "CGV Go Vap"). null if not mentioned.
        unsupported: body or appearance traits asked for. Height ("1m8", "cao 1m7"), weight, looks ("đẹp trai"). Omit otherwise.
        like_me: true when the user wants people similar to themselves, who share their own interests or taste ("same stuff as me", "giống mình", "hợp gu với tôi"). Omit otherwise.

        For a hobby-mode query leave skills and job_title_keywords empty. For a work-mode query leave interest_groups empty.

        Omit any field that is null or empty. Do not emit null or [] values. Output compact JSON on one line, no explanation.

        Example: "tìm bạn nữ xem Kimetsu no Yaiba ở Hà Nội"
        {"intent_en":"find female friend who watches Kimetsu no Yaiba in Hanoi","mode":"hobby","target_gender":"female","entity_type":"anime","entity_name":"Kimetsu no Yaiba","interest_groups":[["anime","manga"]],"location":"Hanoi"}

        Example: "find senior iOS developer who knows React in Ho Chi Minh"
        {"intent_en":"find senior iOS developer who knows React in Ho Chi Minh","mode":"work","entity_type":"framework","entity_name":"React","skills":["iOS","Swift","React"],"bio_keywords":["senior"],"job_title_keywords":["developer"],"location":"Ho Chi Minh"}

        Example: "tìm bạn nam trên 25 tuổi thích đá banh gần CGV Go Vap"
        {"intent_en":"find male friend over 25 years old who likes football near CGV Go Vap","mode":"hobby","target_gender":"male","target_age_min":25,"interest_groups":[["football","soccer"]],"place_name":"CGV Go Vap"}
        """
    }

    static let translatePrompt = """
        Translate the following text to English.
        Rules:
        - Preserve all proper nouns exactly as written: movie/anime/song titles, artist names, team names, brand/company names, university names, framework and tool names, place names
        - Output ONLY the translated English text. No explanation, no quotes, no extra text
        - If the input is already in English, output it unchanged
        """

    static let entertainmentTypes: Set<String> = [
        "anime","manga","movie","tv_show","book","game","music","podcast","celebrity","art","food","sport",
    ]
    static let workTypes: Set<String> = [
        "company","university","industry","programming_language","framework","tool","certification","job_role","professional_field","startup",
    ]

    // MARK: low-level HTTP

    private static func chat(_ cfg: Config, system: String, user: String, temperature: Double, schema: [String: Any]? = nil) async throws -> String {
        var body: [String: Any] = [
            "model": cfg.model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
            "options": ["temperature": temperature],
            "stream": false,
            "keep_alive": keepAlive,
        ]
        if let schema { body["format"] = schema }
        var req = HTTPClientRequest(url: "\(cfg.url)/api/chat")
        req.method = .POST
        req.headers.add(name: "content-type", value: "application/json")
        req.body = .bytes(try JSONSerialization.data(withJSONObject: body))
        let res = try await OllamaGate.run { try await cfg.client.execute(req, timeout: .seconds(60)) }
        guard (200..<300).contains(Int(res.status.code)) else {
            throw Abort(.badGateway, reason: "Ollama error: \(res.status.code)")
        }
        let buf = try await res.body.collect(upTo: 4 * 1024 * 1024)
        struct R: Decodable { struct M: Decodable { let content: String? }; let message: M? }
        return (try? JSONDecoder().decode(R.self, from: buf))?.message?.content ?? ""
    }

    /// Strip markdown fences and parse the JSON object in LLM output.
    private static func parseObject(_ raw: String) throws -> [String: Any] {
        var cleaned = raw
        for f in ["```json", "```JSON", "```Json", "```"] { cleaned = cleaned.replacingOccurrences(of: f, with: "") }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        let afterOutput = cleaned.range(of: "Output:").map { cleaned.distance(from: cleaned.startIndex, to: $0.upperBound) } ?? 0
        let searchStart = cleaned.index(cleaned.startIndex, offsetBy: afterOutput)
        guard let s = cleaned.range(of: "{", range: searchStart..<cleaned.endIndex)?.lowerBound,
              let e = cleaned.range(of: "}", options: .backwards)?.upperBound else {
            throw Abort(.internalServerError, reason: "No JSON object in LLM response")
        }
        let slice = String(cleaned[s..<e])
        guard let obj = try JSONSerialization.jsonObject(with: Data(slice.utf8)) as? [String: Any] else {
            throw Abort(.internalServerError, reason: "LLM response not an object")
        }
        return obj
    }

    private static func parseArray(_ raw: String) throws -> [String] {
        var cleaned = raw
        for f in ["```json", "```JSON", "```"] { cleaned = cleaned.replacingOccurrences(of: f, with: "") }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let s = cleaned.firstIndex(of: "["), let e = cleaned.range(of: "]", options: .backwards)?.upperBound else {
            throw Abort(.internalServerError, reason: "No JSON array in LLM response")
        }
        let arr = try JSONSerialization.jsonObject(with: Data(cleaned[s..<e].utf8)) as? [Any] ?? []
        return arr.compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    // MARK: JSON schema for the analyzer (Ollama `format`)

    private static var analyzerSchema: [String: Any] {
        let entityEnum: [Any] = entertainmentTypes.sorted() + workTypes.sorted() + [NSNull()]
        return [
            "type": "object",
            "properties": [
                "intent_en": ["type": "string"],
                "mode": ["type": ["string", "null"], "enum": ["hobby", "work", NSNull()]],
                "target_gender": ["type": ["string", "null"], "enum": ["male", "female", NSNull()]],
                "target_age_min": ["type": ["integer", "null"]],
                "target_age_max": ["type": ["integer", "null"]],
                "entity_type": ["type": ["string", "null"], "enum": entityEnum],
                "entity_name": ["type": ["string", "null"]],
                "interest_groups": ["type": "array", "items": ["type": "array", "items": ["type": "string"]]],
                "skills": ["type": "array", "items": ["type": "string"]],
                "bio_keywords": ["type": "array", "items": ["type": "string"]],
                "job_title_keywords": ["type": "array", "items": ["type": "string"]],
                "location": ["type": ["string", "null"]],
                "place_name": ["type": ["string", "null"]],
                "like_me": ["type": "boolean"],
                "unsupported": ["type": "array", "items": ["type": "string"]],
            ],
            "required": ["intent_en", "mode"],
        ]
    }

    // MARK: keyword sanitisation

    private static let sentimentPrefix = try! NSRegularExpression(
        pattern: #"^(thích|muốn|quan tâm đến|quan tâm|mê|đam mê|hứng thú với|hứng thú|yêu thích|yêu|like|love|enjoy|want to|interested in)\s+"#,
        options: [.caseInsensitive])
    private static let cjk = try! NSRegularExpression(pattern: #"[\x{3000}-\x{303F}\x{3040}-\x{30FF}\x{AC00}-\x{D7AF}\x{4E00}-\x{9FFF}]"#)
    private static let invalidAdjectives: Set<String> = [
        "thirsty","hungry","romantic","beautiful","pretty","cute","lovely","handsome",
        "funny","happy","sad","lonely","bored","tired","excited","nervous","anxious",
        "smart","clever","kind","nice","cool","awesome","great","good","bad",
        "interesting","amazing","wonderful","fantastic","incredible","brilliant",
        "creative","talented","passionate","enthusiastic","motivated","inspired",
        "active","social","friendly","outgoing","introverted","adventurous","spontaneous",
        "calm","relaxed","busy","lazy","serious","playful","wild","gentle","strong",
        "hunger","thirst","appetite","craving","desire","longing","feeling","emotion",
        "mood","vibe","energy","spirit","soul","mind","heart","love","hate",
        "thick drink","thick","drink food","good food","tasty","delicious","yummy",
        "nice food","good drink","thing","stuff","things","something","everything",
    ]
    static func cleanKeywords(_ arr: [String]?) -> [String] {
        (arr ?? []).map { raw -> String in
            let r = NSRange(raw.startIndex..., in: raw)
            return sentimentPrefix.stringByReplacingMatches(in: raw, range: r, withTemplate: "").trimmingCharacters(in: .whitespaces)
        }.filter { k in
            guard !k.isEmpty else { return false }
            if cjk.firstMatch(in: k, range: NSRange(k.startIndex..., in: k)) != nil { return false }
            return !invalidAdjectives.contains(k.lowercased())
        }
    }

    // MARK: analyze

    struct SearchCriteria: Content {
        var intent_en: String
        @NullCoded var target_gender: String?
        @NullCoded var target_age_min: Int?
        @NullCoded var target_age_max: Int?
        @NullCoded var entity_type: String?
        @NullCoded var entity_name: String?
        var entity_keywords: [String]
        var interest_groups: [[String]]
        var interests: [String]
        var skills: [String]
        var bio_keywords: [String]
        var job_title_keywords: [String]
        @NullCoded var location: String?
        @NullCoded var place_name: String?
        @NullCoded var mode: String?
        /// "Someone into the same stuff as me": your own taste becomes part
        /// of the query (AI_SEARCH_REVIEW.md, phase S2).
        var like_me = false
        /// Height, weight or looks asked for, not searchable (phase S6).
        var unsupported: [String] = []
    }

    /// The analyzer misses some "like me" phrasings, so these always count.
    private static let likeMePattern = try! NSRegularExpression(
        pattern: #"\b(like me|same (stuff|things|interests|taste|vibe)( as me)?|similar to me)\b|(giống|như|hợp gu( với)?|cùng gu( với)?) (mình|tôi|tớ|tui)\b"#,
        options: [.caseInsensitive])
    static func mentionsLikeMe(_ query: String) -> Bool {
        likeMePattern.firstMatch(in: query, range: NSRange(query.startIndex..., in: query)) != nil
    }

    private struct Analyzed {
        var intent_en: String
        var mode: String?
        var target_gender: String?
        var target_age_min: Int?
        var target_age_max: Int?
        var entity_type: String?
        var entity_name: String?
        var interest_groups: [[String]]
        var skills: [String]
        var bio_keywords: [String]
        var job_title_keywords: [String]
        var location: String?
        var place_name: String?
        var like_me = false
        var unsupported: [String] = []
        /// The LLM call failed and these are the defaults; never cached.
        var failed = false
    }

    private static func sanitizeAge(_ rawMin: Any?, _ rawMax: Any?) -> (Int?, Int?) {
        func clean(_ v: Any?) -> Int? {
            let n: Int?
            if let i = v as? Int { n = i }
            else if let d = v as? Double, d == d.rounded() { n = Int(d) }
            else if let s = v as? String { n = Int(s) }
            else { n = nil }
            guard let n, n >= 0, n <= 120 else { return nil }
            return n
        }
        var mn = clean(rawMin), mx = clean(rawMax)
        if let a = mn, let b = mx, a > b { mn = nil; mx = nil }
        return (mn, mx)
    }

    private static func strArray(_ v: Any?) -> [String] {
        (v as? [Any])?.compactMap { $0 as? String } ?? []
    }

    private static func analyzeQuery(_ cfg: Config, _ query: String, logger: Logger) async -> Analyzed {
        do {
            let raw = try await chat(cfg, system: analyzerPrompt, user: query, temperature: 0.1, schema: analyzerSchema)
            let j = try parseObject(raw)
            let (amin, amax) = sanitizeAge(j["target_age_min"], j["target_age_max"])
            let intent = (j["intent_en"] as? String)?.trimmingCharacters(in: .whitespaces)
            let rawGroups = (j["interest_groups"] as? [Any])?.compactMap { $0 as? [Any] }
                .map { $0.compactMap { $0 as? String } } ?? []
            return Analyzed(
                intent_en: (intent?.isEmpty == false ? intent! : query),
                mode: ["hobby", "work"].contains(j["mode"] as? String ?? "") ? (j["mode"] as? String) : nil,
                target_gender: ["male", "female"].contains(j["target_gender"] as? String ?? "") ? (j["target_gender"] as? String) : nil,
                target_age_min: amin, target_age_max: amax,
                entity_type: (j["entity_type"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                entity_name: (j["entity_name"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                interest_groups: rawGroups,
                skills: strArray(j["skills"]),
                bio_keywords: strArray(j["bio_keywords"]),
                job_title_keywords: strArray(j["job_title_keywords"]),
                location: j["location"] as? String,
                place_name: j["place_name"] as? String,
                like_me: j["like_me"] as? Bool ?? false,
                unsupported: strArray(j["unsupported"]))
        } catch {
            logger.warning("Query analyzer failed, using defaults: \(error)")
            return Analyzed(intent_en: query, mode: nil, target_gender: nil, target_age_min: nil, target_age_max: nil,
                            entity_type: nil, entity_name: nil, interest_groups: [], skills: [], bio_keywords: [],
                            job_title_keywords: [], location: nil, place_name: nil, failed: true)
        }
    }

    static let validLocations: Set<String> = Set(
        locationList.split(separator: "|").map { $0.replacingOccurrences(of: "\"", with: "").trimmingCharacters(in: .whitespaces).lowercased() })

    private static func reconcileLocation(_ location: String?, _ placeName: String?) -> (String?, String?) {
        let loc = location?.trimmingCharacters(in: .whitespaces) ?? ""
        let place = placeName?.trimmingCharacters(in: .whitespaces) ?? ""
        if !loc.isEmpty, !validLocations.contains(loc.lowercased()) {
            return (nil, place.isEmpty ? loc : place)
        }
        return (loc.isEmpty ? nil : loc, place.isEmpty ? nil : place)
    }

    /// How long a prompt's reading is reused: the slowest step of a search,
    /// and the same prompt reads the same way.
    static let criteriaCacheHours = 24

    static func criteriaCacheKey(_ query: String, mode: String?) -> String {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return "\(mode ?? "-")|\(words)"
    }

    /// `db` turns on the cache (`search_criteria_cache`, migration 086).
    static func extractSearchCriteria(_ cfg: Config, _ userQuery: String, mode: String?, logger: Logger,
                                      db: (any SQLDatabase)? = nil) async -> SearchCriteria {
        let key = criteriaCacheKey(userQuery, mode: mode)
        struct Cached: Decodable { let criteria: String }
        if let db, let row = try? await db.raw("""
            SELECT criteria::text AS criteria FROM search_criteria_cache
            WHERE key = \(bind: key) AND created_at > NOW() - make_interval(hours => \(bind: criteriaCacheHours))
            """).first(decoding: Cached.self),
           let hit = try? JSONDecoder().decode(SearchCriteria.self, from: Data(row.criteria.utf8)) {
            return hit
        }
        let (criteria, failed) = await analyzeCriteria(cfg, userQuery, mode: mode, logger: logger)
        if let db, !failed, let json = try? JSONEncoder().encode(criteria) {
            try? await db.raw("""
                INSERT INTO search_criteria_cache (key, criteria)
                VALUES (\(bind: key), \(bind: String(decoding: json, as: UTF8.self))::jsonb)
                ON CONFLICT (key) DO UPDATE SET criteria = EXCLUDED.criteria, created_at = NOW()
                """).run()
        }
        return criteria
    }

    private static func analyzeCriteria(_ cfg: Config, _ userQuery: String, mode: String?,
                                        logger: Logger) async -> (SearchCriteria, failed: Bool) {
        let a = await analyzeQuery(cfg, userQuery.trimmingCharacters(in: .whitespaces), logger: logger)
        let resolvedMode = mode ?? a.mode

        var groups = a.interest_groups.filter { !$0.isEmpty }.map { cleanKeywords($0) }.filter { !$0.isEmpty }
        var interests = Array(Set(groups.flatMap { $0 }))
        var skills = cleanKeywords(a.skills)
        var jobKw = cleanKeywords(a.job_title_keywords)
        var entityType = a.entity_type
        var entityName = a.entity_name

        if resolvedMode == "hobby" {
            skills = []; jobKw = []
            if let et = entityType, workTypes.contains(et) { entityType = nil; entityName = nil }
        }
        if resolvedMode == "work" {
            groups = []; interests = []
            if let et = entityType, entertainmentTypes.contains(et) { entityType = nil; entityName = nil }
        }
        let (loc, place) = reconcileLocation(a.location, a.place_name)

        return (SearchCriteria(
            intent_en: a.intent_en,
            target_gender: a.target_gender,
            target_age_min: a.target_age_min,
            target_age_max: a.target_age_max,
            entity_type: entityType,
            entity_name: entityName,
            entity_keywords: [],
            interest_groups: groups,
            interests: interests,
            skills: skills,
            bio_keywords: cleanKeywords(a.bio_keywords),
            job_title_keywords: jobKw,
            location: loc,
            place_name: place,
            mode: resolvedMode,
            like_me: a.like_me || mentionsLikeMe(userQuery),
            unsupported: cleanKeywords(a.unsupported)), a.failed)
    }

    // MARK: "why they fit you" (AI_SEARCH_REVIEW.md, phase S4)

    static func explainPrompt(vietnamese: Bool) -> String {
        """
        You write one short sentence per person explaining why they could be a good fit for the searcher, for a social app's search results.
        Input JSON: "query" (what the searcher asked for), "searcher" (their own interests), and "people" (each with an "id" and "evidence": what they post or say about themselves).
        Rules:
        - Write exactly one sentence for every id in "people", never skip one.
        - Use only facts in the evidence and the searcher's interests. Never invent facts.
        - Say only what fits: what they share with the searcher, or what in their evidence matches the query. No "but", "though" or differences.
        - At most 20 words each, friendly, \(vietnamese ? "starting like \"Hai bạn đều…\" or \"Bạn ấy hay đăng về…\"" : "starting like \"You both…\" or \"They post about…\"").
        - Write in \(vietnamese ? "Vietnamese" : "English").
        Output a JSON object mapping each id to its sentence, nothing else.
        """
    }

    struct ExplainPerson: Encodable { let id: String; let evidence: [String] }

    /// One batched call for the top people. Empty on any failure. The
    /// evidence chips are already on screen, so the sentence is optional.
    static func explainFits(_ cfg: Config, query: String, searcherInterests: [String], people: [ExplainPerson],
                            vietnamese: Bool, logger: Logger) async -> [String: String] {
        guard !people.isEmpty else { return [:] }
        struct In: Encodable { let query: String; let searcher: [String]; let people: [ExplainPerson] }
        var out: [String: String] = [:]
        // The model now and then skips someone; ask once more for just them.
        for _ in 0..<2 {
            let missing = people.filter { out[$0.id] == nil }
            guard !missing.isEmpty else { break }
            do {
                let input = String(decoding: try JSONEncoder().encode(
                    In(query: query, searcher: searcherInterests, people: missing)), as: UTF8.self)
                let obj = try parseObject(try await chat(cfg, system: explainPrompt(vietnamese: vietnamese),
                                                         user: input, temperature: 0.3))
                let ids = Set(missing.map(\.id))
                for (key, value) in obj where ids.contains(key) {
                    guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !text.isEmpty else { continue }
                    out[key] = String(text.prefix(200))
                }
            } catch {
                logger.warning("explainFits failed: \(error)")
            }
        }
        return out
    }

    // MARK: translate + embed

    /// Folded fix: throw on Ollama failure so the caller's retry re-runs it.
    static func translateToEnglish(_ cfg: Config, _ text: String) async throws -> String {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return text }
        let out = try await chat(cfg, system: translatePrompt, user: text, temperature: 0)
        let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? text : trimmed
    }

    static func embedText(_ cfg: Config, _ text: String, logger: Logger) async -> [Double]? {
        do {
            var req = HTTPClientRequest(url: "\(cfg.url)/api/embeddings")
            req.method = .POST
            req.headers.add(name: "content-type", value: "application/json")
            req.body = .bytes(try JSONSerialization.data(withJSONObject: [
                "model": embedModel, "prompt": text, "keep_alive": keepAlive,
            ]))
            let res = try await OllamaGate.run { try await cfg.client.execute(req, timeout: .seconds(15)) }
            guard (200..<300).contains(Int(res.status.code)) else { throw Abort(.badGateway, reason: "Embed \(res.status.code)") }
            let buf = try await res.body.collect(upTo: 2 * 1024 * 1024)
            struct R: Decodable { let embedding: [Double]? }
            return try JSONDecoder().decode(R.self, from: buf).embedding
        } catch {
            logger.warning("embedText failed: \(error)")
            return nil
        }
    }

    /// mxbai's retrieval instruction: a short query embedded with it lands
    /// nearer the passages about it than the bare words do. Stored chunks are
    /// embedded without it.
    static let queryInstruction = "Represent this sentence for searching relevant passages: "

    static func embedQuery(_ cfg: Config, _ text: String, logger: Logger) async -> [Double]? {
        await embedText(cfg, queryInstruction + text, logger: logger)
    }

    /// Raw one-shot chat used by `PostAnalyzeService` / `PostTagExtractService`.
    static func rawChatObject(_ cfg: Config, system: String, user: String, temperature: Double) async throws -> [String: Any] {
        try parseObject(try await chat(cfg, system: system, user: user, temperature: temperature))
    }
    static func rawChatArray(_ cfg: Config, system: String, user: String, temperature: Double) async throws -> [String] {
        try parseArray(try await chat(cfg, system: system, user: user, temperature: temperature))
    }
}

extension Application {
    /// Shared Ollama config (reuses the app's shared AsyncHTTPClient).
    var ollama: OllamaService.Config {
        OllamaService.Config(appEnv.ollama, client: http.client.shared)
    }
}
extension Request {
    var ollama: OllamaService.Config { application.ollama }
}

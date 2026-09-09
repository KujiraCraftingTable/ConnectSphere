import Vapor
import SQLKit

/// Port of `backend/src/controllers/searchController.js` + `searchRoutes.js`.
/// `POST /api/search/ai` (rate-limited — folded fix), `GET /api/search/suggestions`,
/// `POST /api/search/lookup` (exact + vector tiers; the Wikipedia self-learn
/// tier and venue geocoding land in Phase 8).
struct SearchController {
    static let wEntity = 0.7
    static let wGeneral = 0.3
    static let evidencePerUser = 5

    static func register(routes: any RoutesBuilder) {
        let s = routes.grouped("search").grouped(AuthMiddleware())
        s.grouped(RateLimitMiddleware.aiSearch()).post("ai", use: aiSearch)
        s.get("suggestions", use: suggestions)
        s.post("lookup", use: lookup)
    }

    // MARK: response shapes

    struct EvidenceItem: Content {
        var type: String
        @NullCoded var topic: String?
        @NullCoded var similarity: Double?
        var matched_terms: [String]
        @NullCoded var post_count: Int?
        @NullCoded var latest_post_at: Date?
        @NullCoded var oldest_post_at: Date?
        var community_name: String?
    }
    struct SearchUser: Content {
        var id: String; var username: String
        @NullCoded var display_name: String?
        @NullCoded var bio: String?
        @NullCoded var avatar_url: String?
        @NullCoded var cover_url: String?
        @NullCoded var avatar_color: String?
        @NullCoded var location: String?
        @NullCoded var job_title: String?
        @NullCoded var company: String?
        @NullCoded var default_mode: String?
        @NullCoded var gender: String?
        @NullCoded var age: Int?
        var follower_count: Int; var following_count: Int; var post_count: Int
        var interests: [String]; var skills: [String]
        var score: Double
        var mutual_count: Int
        var match_evidence: [EvidenceItem]
    }
    struct EntitySuggestion: Content {
        var keyword: String
        var candidates: [Cand]
        struct Cand: Content { var entity_id: String; var canonical_name: String }
    }
    struct Warning: Content { var code: String; @NullCoded var value: String? }
    struct AISearchResponse: Content {
        var data: [SearchUser]
        var criteria: OllamaService.SearchCriteria
        var entity_suggestions: [EntitySuggestion]
        var warnings: [Warning]
    }

    // MARK: POST /api/search/ai

    struct AIBody: Content { var query: String?; var mode: String?; var radiusKm: Double? }

    static func aiSearch(_ req: Request) async throws -> AISearchResponse {
        let b = try req.content.decode(AIBody.self)
        guard let userQuery = b.query?.trimmingCharacters(in: .whitespaces), !userQuery.isEmpty else {
            throw StatusMessageError(.badRequest, "query is required")
        }
        let db = req.db.sql()
        let cfg = req.ollama
        let searcher = req.userID
        let log = req.logger

        let criteria = await OllamaService.extractSearchCriteria(cfg, userQuery, mode: b.mode, logger: log)

        async let ctxTask = SearchStore.getUserContext(searcher, on: db)
        async let entityTask = buildEntityVector(cfg, criteria, on: db, logger: log)
        async let generalTask = buildGeneralVector(cfg, criteria, logger: log)
        let ctx = try await ctxTask
        let entityResult = await entityTask
        let generalVec = await generalTask

        var warnings: [Warning] = []
        // Phase 8: venue geocoding. Until then a place_name without a location
        // simply doesn't filter — surface that.
        if let place = criteria.place_name, criteria.location == nil {
            warnings.append(Warning(code: "venue_unresolved", value: place))
        }

        let entityVec = entityResult.vec
        let entitySuggestions = entityResult.suggestion.map { [$0] } ?? []

        var fallbackVec: [Double]? = nil
        if entityVec == nil, generalVec == nil {
            warnings.append(Warning(code: "query_unclear", value: nil))
            fallbackVec = await OllamaService.embedText(cfg, criteria.intent_en.isEmpty ? userQuery : criteria.intent_en, logger: log)
            if fallbackVec == nil {
                try? await SearchStore.logSearch(userQuery, mode: b.mode, on: db)
                return AISearchResponse(data: [], criteria: criteria, entity_suggestions: entitySuggestions, warnings: warnings)
            }
        }

        let hasDatingIntent = criteria.bio_keywords.contains { SearchStore.datingKeywords.contains($0.lowercased()) }
        let hasInterestGroups = !criteria.interest_groups.isEmpty

        var base = SearchStore.Params(queryVector: [])
        base.mode = b.mode ?? criteria.mode
        base.location = criteria.location
        base.targetGender = criteria.target_gender
        base.targetAgeMin = criteria.target_age_min
        base.targetAgeMax = criteria.target_age_max
        base.hasDatingIntent = hasDatingIntent
        base.currentUserGender = ctx?.gender
        base.radiusKm = b.radiusKm
        base.excludeUserID = searcher
        base.threshold = 0.6

        var users: [SearchStore.RawUser]
        if let fv = fallbackVec {
            var pp = base; pp.queryVector = fv
            pp.interestGroups = hasInterestGroups ? criteria.interest_groups : nil
            users = try await SearchStore.vectorSearch(pp, on: db)
        } else {
            async let entityRows: [SearchStore.RawUser] = {
                guard let ev = entityVec else { return [] }
                var pp = base; pp.queryVector = ev; pp.interestGroups = nil
                return try await SearchStore.vectorSearch(pp, on: db)
            }()
            async let generalRows: [SearchStore.RawUser] = {
                guard let gv = generalVec else { return [] }
                var pp = base; pp.queryVector = gv
                pp.interestGroups = hasInterestGroups ? criteria.interest_groups : nil
                return try await SearchStore.vectorSearch(pp, on: db)
            }()
            users = mergeWeighted(try await entityRows, try await generalRows)
        }

        let terms = collectCriteriaTerms(criteria)
        var communityByUser: [String: [String]] = [:]
        do {
            communityByUser = try await SearchStore.findCommunityEvidence(users.map(\.id), terms: terms, on: db)
        } catch { log.warning("Community evidence lookup failed: \(error)") }

        let finalUsers = finalize(users, terms: terms, communityByUser: communityByUser)
        try? await SearchStore.logSearch(userQuery, mode: b.mode, on: db)

        return AISearchResponse(data: finalUsers, criteria: criteria,
                                entity_suggestions: entitySuggestions, warnings: warnings)
    }

    // MARK: query builder

    struct EntityVecResult { var vec: [Double]?; var suggestion: EntitySuggestion? }

    static func buildEntityVector(_ cfg: OllamaService.Config, _ c: OllamaService.SearchCriteria,
                                  on db: any SQLDatabase, logger: Logger) async -> EntityVecResult {
        guard let name = c.entity_name else { return EntityVecResult(vec: nil, suggestion: nil) }

        for term in [name] + c.entity_keywords {
            if let hit = try? await SearchStore.exactMatch(term, category: nil, on: db) {
                return EntityVecResult(vec: await OllamaService.embedText(cfg, hit.canonical_name, logger: logger), suggestion: nil)
            }
        }
        guard let nameVec = await OllamaService.embedText(cfg, name, logger: logger) else {
            return EntityVecResult(vec: nil, suggestion: nil)
        }
        let cands = (try? await SearchStore.findEntityCandidates(nameVec, category: c.entity_type, limit: 3, on: db)) ?? []
        if let top = cands.first, top.similarity >= SearchStore.highConfidenceThreshold {
            // Phase 8: background lookupEntity() alias auto-save.
            return EntityVecResult(vec: await OllamaService.embedText(cfg, top.canonical_name, logger: logger), suggestion: nil)
        }
        let grey = cands.filter { $0.similarity >= SearchStore.suggestThreshold }
        if !grey.isEmpty {
            return EntityVecResult(vec: nameVec, suggestion: EntitySuggestion(
                keyword: name,
                candidates: grey.map { .init(entity_id: $0.entity_id, canonical_name: $0.canonical_name) }))
        }
        // Phase 8: background Wikipedia self-learn.
        return EntityVecResult(vec: nameVec, suggestion: nil)
    }

    static func buildGeneralVector(_ cfg: OllamaService.Config, _ c: OllamaService.SearchCriteria, logger: Logger) async -> [Double]? {
        let terms = c.interests + c.skills
        guard !terms.isEmpty else { return nil }
        return await OllamaService.embedText(cfg, terms.joined(separator: ", "), logger: logger)
    }

    // MARK: merge

    static func evidenceKey(_ e: SearchStore.RawEvidence) -> String {
        e.source_type == "user_profile" ? "profile" : "post|\(e.topic ?? "")"
    }
    static func mergeEvidence(_ a: [SearchStore.RawEvidence], _ b: [SearchStore.RawEvidence]) -> [SearchStore.RawEvidence] {
        var byKey: [String: SearchStore.RawEvidence] = [:]
        for ev in a + b {
            let k = evidenceKey(ev)
            if let prev = byKey[k], (ev.similarity ?? 0) <= (prev.similarity ?? 0) { continue }
            byKey[k] = ev
        }
        return Array(byKey.values).sorted { ($0.similarity ?? 0) > ($1.similarity ?? 0) }.prefix(evidencePerUser).map { $0 }
    }

    static func decodeEvidence(_ raw: String) -> [SearchStore.RawEvidence] {
        (try? JSONCoding.makeDecoder().decode([SearchStore.RawEvidence].self, from: Data(raw.utf8))) ?? []
    }

    static func mergeWeighted(_ entitySet: [SearchStore.RawUser], _ generalSet: [SearchStore.RawUser]) -> [SearchStore.RawUser] {
        var map: [String: SearchStore.RawUser] = [:]
        var evMap: [String: [SearchStore.RawEvidence]] = [:]
        for u in entitySet {
            var uu = u; uu.score = wEntity * u.score
            map[u.id] = uu; evMap[u.id] = decodeEvidence(u.match_evidence)
        }
        for u in generalSet {
            let genEv = decodeEvidence(u.match_evidence)
            if var merged = map[u.id] {
                merged.score += wGeneral * u.score
                map[u.id] = merged
                evMap[u.id] = mergeEvidence(evMap[u.id] ?? [], genEv)
            } else {
                var uu = u; uu.score = wGeneral * u.score
                map[u.id] = uu; evMap[u.id] = genEv
            }
        }
        return map.values.sorted { $0.score > $1.score }.map { u -> SearchStore.RawUser in
            var uu = u
            let enc = (try? JSONCoding.makeEncoder().encode(evMap[u.id] ?? [])) ?? Data("[]".utf8)
            uu.match_evidence = String(data: enc, encoding: .utf8) ?? "[]"
            return uu
        }
    }

    // MARK: finalize evidence

    static func collectCriteriaTerms(_ c: OllamaService.SearchCriteria) -> [String] {
        var terms = Set<String>()
        if let n = c.entity_name { terms.insert(n) }
        c.entity_keywords.forEach { terms.insert($0) }
        c.interest_groups.forEach { $0.forEach { terms.insert($0) } }
        c.skills.forEach { terms.insert($0) }
        c.bio_keywords.forEach { terms.insert($0) }
        c.job_title_keywords.forEach { terms.insert($0) }
        return terms.filter { $0.trimmingCharacters(in: .whitespaces).count >= 2 }
    }

    static func finalize(_ users: [SearchStore.RawUser], terms: [String], communityByUser: [String: [String]]) -> [SearchUser] {
        users.map { u in
            let raw = decodeEvidence(u.match_evidence)
            let chunkEv: [EvidenceItem] = raw.map { ev in
                let content = (ev.content ?? "").lowercased()
                let matched = terms.filter { content.contains($0.lowercased()) }
                return EvidenceItem(
                    type: ev.source_type == "user_profile" ? "profile" : "post",
                    topic: ev.topic, similarity: ev.similarity,
                    matched_terms: Array(matched.prefix(3)),
                    post_count: ev.post_count, latest_post_at: ev.latest_post_at, oldest_post_at: ev.oldest_post_at,
                    community_name: nil)
            }
            let commEv: [EvidenceItem] = (communityByUser[u.id] ?? []).map { name in
                EvidenceItem(type: "community", topic: nil, similarity: nil, matched_terms: [],
                             post_count: nil, latest_post_at: nil, oldest_post_at: nil, community_name: name)
            }
            let chunkSlots = evidencePerUser - min(commEv.count, 2)
            let evidence = Array((Array(chunkEv.prefix(max(0, chunkSlots))) + commEv).prefix(evidencePerUser))
            let dec = JSONDecoder()
            return SearchUser(
                id: u.id, username: u.username, display_name: u.display_name, bio: u.bio,
                avatar_url: u.avatar_url, cover_url: u.cover_url, avatar_color: u.avatar_color,
                location: u.location, job_title: u.job_title, company: u.company,
                default_mode: u.default_mode, gender: u.gender, age: u.age,
                follower_count: u.follower_count, following_count: u.following_count, post_count: u.post_count,
                interests: (try? dec.decode([String].self, from: Data(u.interests.utf8))) ?? [],
                skills: (try? dec.decode([String].self, from: Data(u.skills.utf8))) ?? [],
                score: u.score, mutual_count: u.mutual_count, match_evidence: evidence)
        }
    }

    // MARK: GET /api/search/suggestions

    struct SuggestionsResponse: Content { var suggestions: [String] }
    static let defaultSuggestions: [String: [String]] = [
        "hobby": [
            "tìm bạn thích anime để hẹn hò cuối tuần",
            "tìm người có cùng sở thích xem phim",
            "tìm bạn chơi game online cùng",
            "tìm người thích du lịch khám phá",
        ],
        "work": [
            "tìm iOS developer sinh viên có hứng thú chung",
            "tìm đồng nghiệp làm React ở Hồ Chí Minh",
            "tìm sinh viên kế toán muốn học nhóm",
            "tìm designer có kinh nghiệm Figma",
        ],
    ]
    /// Phase 8 ports the LLM-cached trending-query suggestions; until then this
    /// serves the same static defaults Node falls back to.
    static func suggestions(_ req: Request) async throws -> SuggestionsResponse {
        let mode = try? req.query.get(String.self, at: "mode")
        if mode == "hobby" || mode == "work" {
            return SuggestionsResponse(suggestions: defaultSuggestions[mode!]!)
        }
        return SuggestionsResponse(suggestions: Array((defaultSuggestions["hobby"]! + defaultSuggestions["work"]!).prefix(4)))
    }

    // MARK: POST /api/search/lookup  (exact + vector tiers only; Wikipedia = Phase 8)

    struct LookupBody: Content { var text: String?; var category: String? }
    struct LookupResult: Content {
        @NullCoded var entity_id: String?
        @NullCoded var canonical_name: String?
        @NullCoded var category: String?
        var confidence: String
    }
    static func lookup(_ req: Request) async throws -> LookupResult {
        let b = try req.content.decode(LookupBody.self)
        guard let text = b.text?.trimmingCharacters(in: .whitespaces), !text.isEmpty else {
            throw InlineError(.badRequest, "text is required")
        }
        let db = req.db.sql()
        if let hit = try await SearchStore.exactMatch(text, category: b.category, on: db) {
            return LookupResult(entity_id: hit.id, canonical_name: hit.canonical_name, category: hit.category, confidence: "exact")
        }
        if let vec = await OllamaService.embedText(req.ollama, text, logger: req.logger),
           let top = (try? await SearchStore.findEntityCandidates(vec, category: b.category, limit: 1, on: db))?.first,
           top.similarity >= SearchStore.highConfidenceThreshold {
            // Phase 8: saveAlias(text, top.entity_id) fire-and-forget.
            return LookupResult(entity_id: top.entity_id, canonical_name: top.canonical_name, category: top.category, confidence: "vector")
        }
        return LookupResult(entity_id: nil, canonical_name: nil, category: nil, confidence: "none")
    }
}

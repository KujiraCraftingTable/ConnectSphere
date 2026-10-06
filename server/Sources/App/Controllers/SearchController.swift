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
        s.grouped(RateLimitMiddleware.aiSearch()).post("ai", "posts", use: aiPostSearch)
        s.get("suggestions", use: suggestions)
        s.post("lookup", use: lookup)

        // Phase 8: entity alias confirm + venue clarification.
        routes.grouped("entities").grouped(AuthMiddleware()).post("alias", use: entityAlias)
        routes.grouped("locations").grouped(AuthMiddleware())
            .grouped(RateLimitMiddleware.clarify()).post("clarify", use: locationClarify)
    }

    // MARK: POST /api/entities/alias

    struct AliasBody: Content { var keyword: String?; var entity_id: String? }
    struct AliasOK: Content { var status = "ok"; var canonical_name: String }
    static func entityAlias(_ req: Request) async throws -> AliasOK {
        let b = try req.content.decode(AliasBody.self)
        guard let kw = b.keyword?.trimmingCharacters(in: .whitespaces), !kw.isEmpty, let eid = b.entity_id else {
            throw StatusMessageError(.badRequest, "keyword and entity_id are required")
        }
        guard let canonical = try await EntityLookupService.saveAlias(kw, entityID: eid, on: req.db.sql()) else {
            throw StatusMessageError(.notFound, "Entity not found")
        }
        return AliasOK(canonical_name: canonical)
    }

    // MARK: POST /api/locations/clarify

    struct ClarifyBody: Content { var alias: String?; var canonical: String? }
    struct ClarifyOK: Content {
        var status = "ok"; var resolved: Bool
        @NullCoded var province_name: String?; @NullCoded var lat: Double?; @NullCoded var lng: Double?
    }
    static func locationClarify(_ req: Request) async throws -> ClarifyOK {
        let b = try req.content.decode(ClarifyBody.self)
        guard let alias = b.alias?.trimmingCharacters(in: .whitespaces), !alias.isEmpty,
              let canonical = b.canonical?.trimmingCharacters(in: .whitespaces), !canonical.isEmpty else {
            throw StatusMessageError(.badRequest, "alias and canonical are required")
        }
        guard alias.count <= 100, canonical.count <= 100 else {
            throw StatusMessageError(.badRequest, "alias and canonical must be 100 characters or fewer")
        }
        let r = try await VenueLocationService.recordClarification(
            alias: alias, canonical: canonical, userID: req.userID,
            client: req.application.http.client.shared, on: req.db.sql(), logger: req.logger)
        return ClarifyOK(resolved: r.resolved, province_name: r.province_name, lat: r.lat, lng: r.lng)
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
        /// Engagement evidence: public reactions only (likes are never sent).
        var commented_count: Int? = nil
        var shared_count: Int? = nil
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

        var criteria = await OllamaService.extractSearchCriteria(cfg, userQuery, mode: b.mode, logger: log)

        async let ctxTask = SearchStore.getUserContext(searcher, on: db)
        async let entityTask = buildEntityVector(cfg, criteria, on: db, logger: log)
        async let generalTask = buildGeneralVector(cfg, criteria, logger: log)
        let ctx = try await ctxTask
        let entityResult = await entityTask
        let generalVec = await generalTask

        var warnings: [Warning] = []
        var searchCoords: (lat: Double, lng: Double)? = nil
        if let place = criteria.place_name, criteria.location == nil {
            if let loc = await VenueLocationService.resolveVenueToCity(
                place, client: HTTPClient.shared, on: db, logger: log), let prov = loc.provinceName {
                criteria.location = prov
                if let la = loc.lat, let ln = loc.lng { searchCoords = (la, ln) }
            } else {
                warnings.append(Warning(code: "venue_unresolved", value: place))
            }
        } else if let loc = criteria.location, b.radiusKm != nil,
                  let g = await VenueLocationService.resolveVenueToCity(loc, client: HTTPClient.shared, on: db, logger: log),
                  let la = g.lat, let ln = g.lng {
            searchCoords = (la, ln)
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
        base.searchLat = searchCoords?.lat
        base.searchLng = searchCoords?.lng
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

    // MARK: POST /api/search/ai/posts

    struct AIPostSearchResponse: Content {
        var data: [PostObject]
        var criteria: OllamaService.SearchCriteria
        var warnings: [Warning]
        /// Post id → cosine similarity (0…1) of its best-matching query vector.
        /// It is both the ranking key and the match % the app shows, so the
        /// order and the percentages can never disagree.
        var match_scores: [String: Double]
    }

    /// AI search over posts: the same LLM breakdown and query vectors as
    /// people search, then nearest post chunks. Each post keeps its best
    /// similarity across the vectors. Radius/location filters don't apply —
    /// posts carry no location.
    static func aiPostSearch(_ req: Request) async throws -> AIPostSearchResponse {
        let b = try req.content.decode(AIBody.self)
        guard let userQuery = b.query?.trimmingCharacters(in: .whitespaces), !userQuery.isEmpty else {
            throw StatusMessageError(.badRequest, "query is required")
        }
        if let m = b.mode, !["hobby", "work"].contains(m) {
            throw StatusMessageError(.badRequest, "mode must be hobby or work")
        }
        let db = req.db.sql()
        let cfg = req.ollama
        let log = req.logger

        let criteria = await OllamaService.extractSearchCriteria(cfg, userQuery, mode: b.mode, logger: log)
        async let entityTask = buildEntityVector(cfg, criteria, on: db, logger: log)
        async let generalTask = buildGeneralVector(cfg, criteria, logger: log)
        var vectors = [await entityTask.vec, await generalTask].compactMap { $0 }

        // The breakdown prompt is written for finding *people*, so a post query
        // ("posts about …") often yields no interests/entity. Embedding the
        // whole query is then the normal path, not a failure — only warn when
        // no vector could be built at all.
        var warnings: [Warning] = []
        if vectors.isEmpty {
            if let fv = await OllamaService.embedText(cfg, criteria.intent_en.isEmpty ? userQuery : criteria.intent_en, logger: log) {
                vectors = [fv]
            } else {
                warnings.append(Warning(code: "query_unclear", value: nil))
            }
        }
        let mode = b.mode ?? criteria.mode
        var best: [String: Double] = [:]
        try await withThrowingTaskGroup(of: [SearchStore.PostHit].self) { group in
            for v in vectors {
                group.addTask { try await SearchStore.nearestPosts(v, mode: mode, on: db) }
            }
            for try await hits in group {
                for h in hits { best[h.id] = max(best[h.id] ?? 0, h.sim) }
            }
        }

        let visible = try await PostStore.findVisible(Array(best.keys), viewer: req.userID, on: db)
        // Engagement only reorders; `match_scores` below stays the pure match.
        func rank(_ p: PostObject) -> Double {
            PostRanking.rankScore(similarity: best[p.id] ?? 0, likes: p.like_count, comments: p.comment_count)
        }
        let ranked = visible
            .sorted { rank($0) > rank($1) }
            .prefix(20)
        try? await SearchStore.logSearch(userQuery, mode: b.mode, on: db)
        return AIPostSearchResponse(
            data: Array(ranked), criteria: criteria, warnings: warnings,
            match_scores: Dictionary(uniqueKeysWithValues: ranked.map { ($0.id, best[$0.id] ?? 0) })
        )
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
            selfLearn(name, category: c.entity_type, cfg: cfg, on: db, logger: logger)
            return EntityVecResult(vec: await OllamaService.embedText(cfg, top.canonical_name, logger: logger), suggestion: nil)
        }
        let grey = cands.filter { $0.similarity >= SearchStore.suggestThreshold }
        if !grey.isEmpty {
            return EntityVecResult(vec: nameVec, suggestion: EntitySuggestion(
                keyword: name,
                candidates: grey.map { .init(entity_id: $0.entity_id, canonical_name: $0.canonical_name) }))
        }
        // No close candidates — the entity may be a new proper noun. Learn it in
        // the background (Wikipedia → interest_entities) so Tier-1 catches it next time.
        selfLearn(name, category: c.entity_type, cfg: cfg, on: db, logger: logger)
        return EntityVecResult(vec: nameVec, suggestion: nil)
    }

    /// Fire-and-forget 3-tier `lookupEntity` — its Tier-2/Tier-3 side effects
    /// (alias save, Wikipedia entity insert) make the next search sharper.
    static func selfLearn(_ name: String, category: String?, cfg: OllamaService.Config,
                          on db: any SQLDatabase, logger: Logger) {
        let client = HTTPClient.shared
        Task.detached {
            _ = await EntityLookupService.lookupEntity(name, category: category, cfg: cfg,
                                                       client: client, on: db, logger: logger)
        }
    }

    static func buildGeneralVector(_ cfg: OllamaService.Config, _ c: OllamaService.SearchCriteria, logger: Logger) async -> [Double]? {
        let terms = c.interests + c.skills
        guard !terms.isEmpty else { return nil }
        return await OllamaService.embedText(cfg, terms.joined(separator: ", "), logger: logger)
    }

    // MARK: merge

    static func evidenceKey(_ e: SearchStore.RawEvidence) -> String {
        switch e.source_type {
        case "user_profile": return "profile"
        case "engagement":   return "engagement|\(e.topic ?? "")"
        default:             return "post|\(e.topic ?? "")"
        }
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
                let type: String
                switch ev.source_type {
                case "user_profile": type = "profile"
                case "engagement":   type = "engagement"
                default:             type = "post"
                }
                return EvidenceItem(
                    type: type,
                    topic: ev.topic, similarity: ev.similarity,
                    matched_terms: Array(matched.prefix(3)),
                    post_count: ev.post_count, latest_post_at: ev.latest_post_at, oldest_post_at: ev.oldest_post_at,
                    community_name: nil,
                    commented_count: ev.commented_count, shared_count: ev.shared_count)
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
    static func suggestions(_ req: Request) async throws -> SuggestionsResponse {
        let mode = try? req.query.get(String.self, at: "mode")
        let list = await SuggestionService.getSuggestions(mode: mode, cfg: req.ollama, on: req.db.sql(), logger: req.logger)
        return SuggestionsResponse(suggestions: list)
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

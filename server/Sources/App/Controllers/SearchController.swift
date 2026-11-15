import Vapor
import SQLKit

/// `POST /api/search/ai` (rate-limited. Folded fix), `GET /api/search/suggestions`,
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
        s.grouped(RateLimitMiddleware.aiSearch()).post("sessions", ":id", "explain", use: explain)
        s.post("sessions", ":id", "events", use: sessionEvent)
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
        /// Ward to ward, rounded up to the next 5 km so it never reads more
        /// precise than a ward is. Null when the search had no radius.
        @NullCoded var distance_km: Int?
    }
    struct EntitySuggestion: Content {
        var keyword: String
        var candidates: [Cand]
        struct Cand: Content { var entity_id: String; var canonical_name: String }
    }
    /// `value_en`: `value` in English, when it is a place name the app shows
    /// in its own language ("Thành phố Thủ Đức" / "Thu Duc City").
    struct Warning: Content { var code: String; @NullCoded var value: String?; @NullCoded var value_en: String? = nil }
    struct AISearchResponse: Content {
        var data: [SearchUser]
        var criteria: OllamaService.SearchCriteria
        var entity_suggestions: [EntitySuggestion]
        var warnings: [Warning]
        /// Ties taps, "Not a fit", refinements and explanations to this search.
        @NullCoded var search_session_id: String?
    }

    // MARK: POST /api/search/ai

    struct AIBody: Content {
        var query: String?; var mode: String?; var radiusKm: Double?
        /// Refining an earlier search of yours (AI_SEARCH_REVIEW.md, phase S4):
        /// its id, plus what to change. Free text ("only in Hanoi"), people
        /// more like one of its results, or closer to where you live.
        var session_id: String?
        var refine: String?
        var more_like: String?
        var closer: Bool?
    }
    static let maxRefineLength = 200
    static let maxQueryLength = 500

    /// The typed query, trimmed. Newlines and tabs count as blanks: a
    /// whitespace-only query that got through made the model invent a search.
    /// The cap keeps one request from tying up Ollama for everyone.
    static func cleanQuery(_ raw: String?) throws -> String {
        let q = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard q.count <= maxQueryLength else {
            throw StatusMessageError(.badRequest, "query must be \(maxQueryLength) characters or fewer")
        }
        return q
    }
    /// Taste vectors used as extra queries for a "like me" prompt.
    static let maxLikeMeVectors = 3
    /// Profiles all read alike to the embedding model (0.6 matches most of
    /// them), so a profile or taste used as the query needs a higher bar.
    static let personalThreshold = 0.7

    static func aiSearch(_ req: Request) async throws -> AISearchResponse {
        let b = try req.content.decode(AIBody.self)
        if let m = b.mode, !["hobby", "work"].contains(m) {
            throw StatusMessageError(.badRequest, "mode must be hobby or work")
        }
        let db = req.db.sql()
        let cfg = req.ollama
        let searcher = req.userID
        let log = req.logger

        var userQuery = try cleanQuery(b.query)
        if let sid = b.session_id {
            guard UUID(uuidString: sid) != nil, let prev = try await SearchStore.session(sid, userID: searcher, on: db) else {
                throw StatusMessageError(.notFound, "Search not found")
            }
            userQuery = prev.query
        }
        if let r = b.refine?.trimmingCharacters(in: .whitespacesAndNewlines), !r.isEmpty {
            guard b.session_id != nil else { throw StatusMessageError(.badRequest, "refine needs session_id") }
            guard r.count <= maxRefineLength else {
                throw StatusMessageError(.badRequest, "refine must be \(maxRefineLength) characters or fewer")
            }
            // The analyzer reads the earlier prompt with the change appended,
            // so the criteria are edited rather than started over.
            userQuery += ". " + r
        }
        guard !userQuery.isEmpty else { throw StatusMessageError(.badRequest, "query is required") }
        // Partner wording ("to date", "người yêu") is ignored; the rest is searched.
        var onlyPartnerWords = false
        if SearchConcepts.mentionsPartner(userQuery) {
            let rest = SearchConcepts.withoutPartnerWords(userQuery)
            if rest.isEmpty { onlyPartnerWords = true } else { userQuery = rest }
        }
        if let ml = b.more_like, UUID(uuidString: ml) == nil {
            throw StatusMessageError(.badRequest, "more_like must be a user id")
        }
        if let r = b.radiusKm, !SearchStore.radiusStepsKm.contains(r) {
            throw StatusMessageError(.badRequest, "radiusKm must be 5, 10, 15, 20, 25 or 30")
        }

        var timer = StepTimer()
        var criteria = await OllamaService.extractSearchCriteria(cfg, userQuery, mode: b.mode, logger: log, db: db)
        timer.mark("criteria")

        async let ctxTask = SearchStore.getUserContext(searcher, on: db)
        async let tasteTask = SearchStore.searchTaste(searcher, mode: b.mode ?? criteria.mode, on: db)
        async let entriesTask = SearchConcepts.searchEntries(mode: b.mode ?? criteria.mode, on: db)
        let ctx = try await ctxTask
        let tastes = try await tasteTask
        let entries = try await entriesTask

        // Every search is recorded (phase S3), empty ones too: the zero-result
        // rate is one of the weekly metrics.
        func respond(_ users: [SearchStore.RawUser], _ warnings: [Warning], terms: [String] = [],
                     communities: [String: [String]] = [:], suggestions: [EntitySuggestion] = []) async -> AISearchResponse {
            let finalUsers = finalize(users, terms: terms, communityByUser: communities)
            try? await SearchStore.logSearch(userQuery, mode: b.mode, on: db)
            var sessionID: String? = nil
            do {
                let criteriaJSON = String(decoding: try JSONEncoder().encode(criteria), as: UTF8.self)
                sessionID = try await SearchStore.recordSession(
                    userID: searcher, query: userQuery, mode: b.mode ?? criteria.mode, criteriaJSON: criteriaJSON,
                    shown: finalUsers.map { ($0.id, $0.score) }, on: db)
            } catch { log.warning("Search session not recorded: \(error)") }
            return AISearchResponse(data: finalUsers, criteria: criteria, entity_suggestions: suggestions,
                                    warnings: warnings, search_session_id: sessionID)
        }

        // Nothing left to search once the partner wording is gone.
        if onlyPartnerWords { return await respond([], [Warning(code: "query_unclear", value: nil)]) }
        // Height, weight and looks aren't stored (phase S6).
        if let trait = SearchConcepts.unsupportedTrait(userQuery) ?? criteria.unsupported.first {
            return await respond([], [Warning(code: "unsupported_trait", value: trait)])
        }
        if !SearchConcepts.mentionsAge(userQuery) {
            criteria.target_age_min = nil
            criteria.target_age_max = nil
        }
        let concepts = await englishConcepts(
            cfg, SearchConcepts.concepts(prompt: userQuery, criteria: criteria, entries: entries), logger: log)

        let parsed = criteria
        async let entityTask = buildEntityVector(cfg, parsed, on: db, logger: log)
        async let generalTask = buildGeneralVector(cfg, parsed, logger: log)
        async let conceptVecTask = conceptVectors(cfg, concepts, logger: log)
        let entityResult = await entityTask
        let generalVec = await generalTask
        let conceptVecs = await conceptVecTask
        timer.mark("vectors")

        var warnings: [Warning] = []
        var searchCoords: (lat: Double, lng: Double)? = nil
        // "Closer to me" with a radius is measured from your ward (below);
        // without one it narrows to your province.
        if b.closer == true, b.radiusKm == nil, criteria.location == nil, criteria.place_name == nil, let home = ctx?.location {
            criteria.location = home
        }
        // A ward, district or address in the prompt ("ở bình thạnh", "45 Lê
        // Thánh Tôn") is read as today's wards; people near them match. The
        // prompt as a whole is read too, for when the LLM drops "quận 1".
        var searchWards: [String] = []
        var placeLabels: [String] = []     // the place as understood, for the "no one near" notice
        let placePhrases = [PlaceReader.placePhrase(in: userQuery), criteria.place_name].compactMap { $0 }
        if !placePhrases.isEmpty {
            do {
                let home = try await WardStore.provinceCode(named: criteria.location, orOfUser: searcher, on: db)
                let found = try await PlaceReader.resolve(placePhrases, homeProvince: home, client: HTTPClient.shared, on: db, logger: log)
                searchWards = Array(found.wardIDs)
                placeLabels = Array(found.labels.prefix(3))
                if searchWards.isEmpty, criteria.location == nil, let code = found.provinceCodes.first, found.provinceCodes.count == 1 {
                    criteria.location = try await WardStore.provinceName(code: code, on: db)
                }
            } catch { log.warning("Place lookup failed: \(error)") }
        }
        if searchWards.isEmpty, let named = try? await PlaceReader.read(userQuery, on: db), !named.wardIDs.isEmpty {
            searchWards = Array(named.wardIDs)
            placeLabels = Array(named.labels.prefix(3))
        }
        if !searchWards.isEmpty {
            // The wards decide; the filter below measures from their centres.
        } else if let place = criteria.place_name, criteria.location == nil {
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
        } else if b.radiusKm != nil, criteria.place_name == nil, criteria.location == nil {
            // No place named: the radius is measured from your own ward.
            searchCoords = try await WardStore.centre(ofUser: searcher, on: db)
        }

        timer.mark("place")
        let entityVec = entityResult.vec
        let entitySuggestions = entityResult.suggestion.map { [$0] } ?? []

        // "Like me" and "More like @x" add vectors of their own: your taste,
        // or that person's profile.
        var personalVecs: [[Double]] = criteria.like_me ? Array(tastes.prefix(maxLikeMeVectors)) : []
        if let ml = b.more_like, let v = try await SearchStore.profileVector(ml, mode: b.mode ?? criteria.mode, on: db) { personalVecs.append(v) }

        let groups = criteria.interest_groups.isEmpty ? nil : criteria.interest_groups
        var base = SearchStore.Params(queryVector: [])
        base.mode = b.mode ?? criteria.mode
        base.location = criteria.location
        base.targetGender = criteria.target_gender
        base.targetAgeMin = criteria.target_age_min
        base.targetAgeMax = criteria.target_age_max
        base.radiusKm = b.radiusKm
        base.searchWardIDs = searchWards
        base.searchLat = searchCoords?.lat
        base.searchLng = searchCoords?.lng
        base.excludeUserID = searcher
        base.threshold = 0.6
        base.interestGroups = groups
        let params = base
        let hasFilter = criteria.target_gender != nil || criteria.target_age_min != nil
            || criteria.target_age_max != nil || criteria.location != nil || searchCoords != nil || !searchWards.isEmpty

        // Names typed in the prompt are found whatever else it asks for.
        var keywordParams = params
        keywordParams.threshold = 0
        keywordParams.keyword = SearchStore.KeywordQuery(terms: keywordTerms(criteria), nameQuery: userQuery)
        let kwRows = try await SearchStore.vectorSearch(keywordParams, on: db)
        timer.mark("keyword")
        let nameHits = kwRows.filter { $0.name_match >= strongNameMatch }

        var users: [SearchStore.RawUser] = []
        if !concepts.isEmpty {
            // The prompt is the gate: only people who match every topic it
            // names. Your taste orders them later; it never adds anyone.
            var gates: [Set<String>] = []
            for (c, v) in zip(concepts, conceptVecs) {
                gates.append(try await SearchStore.conceptPeople(c, vector: v, mode: params.mode, on: db))
            }
            let missing = zip(concepts, gates).filter { $0.1.isEmpty }.map(\.0.label)
            let allowed = gates.dropFirst().reduce(gates[0]) { $0.intersection($1) }
            if allowed.isEmpty {
                if nameHits.isEmpty {
                    warnings.append(missing.isEmpty
                        ? Warning(code: "no_match_together", value: concepts.map(\.label).joined(separator: ", "))
                        : Warning(code: "no_match", value: missing.joined(separator: ", ")))
                }
                users = fuse(semantic: [], keyword: nameHits)
            } else {
                // Within the gate every qualifying person is ranked, so no bar.
                var gated = params
                gated.threshold = 0
                gated.allowedUsers = Array(allowed)
                let g = gated, personal = personalVecs
                async let semanticRows = semanticSearch(g, entityVec: entityVec, generalVec: generalVec, on: db)
                async let personalRows = bestOfVectors(g, personal, on: db)
                let keyword = kwRows.filter { allowed.contains($0.id) || $0.name_match >= strongNameMatch }
                users = fuse(semantic: try await semanticRows, keyword: keyword, personal: try await personalRows)
            }
        } else if !personalVecs.isEmpty {
            var personalParams = params
            personalParams.threshold = personalThreshold
            users = fuse(semantic: [], keyword: nameHits,
                         personal: try await bestOfVectors(personalParams, personalVecs, on: db))
        } else if hasFilter {
            // Only filters ("bạn nữ ở Hà Nội"): everyone who passes them,
            // nearest your taste first.
            var tasteVecs = Array(tastes.prefix(maxLikeMeVectors))
            if tasteVecs.isEmpty, let mine = try await SearchStore.profileVector(searcher, mode: params.mode, on: db) { tasteVecs = [mine] }
            var open = params
            open.threshold = 0
            users = fuse(semantic: [], keyword: nameHits, personal: try await bestOfVectors(open, tasteVecs, on: db))
        } else if !nameHits.isEmpty {
            users = fuse(semantic: [], keyword: nameHits)
        } else {
            warnings.append(Warning(code: "query_unclear", value: nil))
        }

        // People match the rest of the prompt, just none near the place it
        // names: say so rather than show an unexplained empty list.
        let placed = !searchWards.isEmpty || searchCoords != nil || criteria.location != nil
        if users.isEmpty, warnings.isEmpty, placed {
            // The place as the gazetteer spells it, in both languages; the
            // app shows the one it is set to.
            if placeLabels.isEmpty {
                let typed = (criteria.place_name ?? criteria.location)?
                    .trimmingCharacters(in: .whitespaces.union(.punctuationCharacters))
                warnings.append(Warning(code: "no_match_near", value: typed))
            } else {
                warnings.append(Warning(code: "no_match_near", value: placeLabels.joined(separator: "; "),
                                        value_en: placeLabels.map(PlaceReader.english).joined(separator: "; ")))
            }
        }

        timer.mark("retrieval")
        // Who fits *you*, then spread by place (phases S2, S3, S5).
        do {
            let features = try await SearchStore.rankFeatures(searcher: searcher, candidates: users.map(\.id),
                                                              tastes: tastes, mode: params.mode, on: db)
            users = SearchRanking.rerank(users, features: features)
        } catch { log.warning("Search ranking features failed: \(error)") }
        users = SearchRanking.diversify(users, byPlace: criteria.location == nil && searchCoords == nil)

        timer.mark("rerank")
        let terms = collectCriteriaTerms(criteria)
        var communityByUser: [String: [String]] = [:]
        do {
            communityByUser = try await SearchStore.findCommunityEvidence(users.map(\.id), terms: terms, on: db)
        } catch { log.warning("Community evidence lookup failed: \(error)") }
        timer.mark("evidence")
        log.info("ai search timing people \(timer.summary) results=\(users.count)")
        return await respond(users, warnings, terms: terms, communities: communityByUser, suggestions: entitySuggestions)
    }

    // MARK: POST /api/search/sessions/:id/events

    struct EventBody: Content { var user_id: String?; var kind: String? }
    struct StatusOK: Content { var status = "ok" }

    /// The app reports a tap on a result, or "Not a fit".
    static func sessionEvent(_ req: Request) async throws -> StatusOK {
        let b = try req.content.decode(EventBody.self)
        guard let sid = req.parameters.get("id"), UUID(uuidString: sid) != nil,
              let uid = b.user_id, UUID(uuidString: uid) != nil else {
            throw StatusMessageError(.badRequest, "session id and user_id are required")
        }
        guard let kind = b.kind, SearchStore.eventColumns[kind] != nil else {
            throw StatusMessageError(.badRequest, "kind must be tap or dismiss")
        }
        guard try await SearchStore.stampEvent(sessionID: sid, userID: req.userID, shownUserID: uid, kind: kind,
                                               on: req.db.sql()) else {
            throw StatusMessageError(.notFound, "Search result not found")
        }
        return StatusOK()
    }

    /// A connection request or message to someone a recent search showed you
    /// counts for that search (phase S3). Never fails the request.
    static func creditOutcome(_ req: Request, to otherID: String, column: String) {
        let uid = req.userID
        NotifyService.fireAndForget(req) { db, _, log in
            do { try await SearchStore.creditOutcome(from: uid, to: otherID, column: column, on: db) }
            catch { log.warning("Search outcome not credited: \(error)") }
        }
    }

    // MARK: POST /api/search/sessions/:id/explain

    static let explainTop = 5
    struct ExplainBody: Content { var lang: String? }
    struct ExplainResponse: Content { var explanations: [String: String] }

    /// "Why they fit you" for the top results (phase S4): one LLM call grounded
    /// in what they post and what you're into, cached on the session.
    static func explain(_ req: Request) async throws -> ExplainResponse {
        guard let sid = req.parameters.get("id"), UUID(uuidString: sid) != nil else {
            throw StatusMessageError(.badRequest, "session id is required")
        }
        let lang = (try? req.content.decode(ExplainBody.self))?.lang ?? "en"
        guard ["en", "vi"].contains(lang) else { throw StatusMessageError(.badRequest, "lang must be en or vi") }
        let db = req.db.sql()
        guard let session = try await SearchStore.session(sid, userID: req.userID, on: db) else {
            throw StatusMessageError(.notFound, "Search not found")
        }
        // Cached per language: { "en": { user id: sentence }, "vi": … }.
        var cache = session.explanations
            .flatMap { try? JSONDecoder().decode([String: [String: String]].self, from: Data($0.utf8)) } ?? [:]
        if let map = cache[lang] { return ExplainResponse(explanations: map) }
        let people = try await SearchStore.explainEvidence(sessionID: sid, top: explainTop, mode: session.mode, on: db)
        let mine = try await SearchStore.interestsOf(req.userID, on: db)
        let map = await OllamaService.explainFits(req.ollama, query: session.query, searcherInterests: mine,
                                                  people: people, vietnamese: lang == "vi", logger: req.logger)
        cache[lang] = map
        if !map.isEmpty, let json = try? JSONEncoder().encode(cache) {
            try? await SearchStore.saveExplanations(sessionID: sid, json: String(decoding: json, as: UTF8.self), on: db)
        }
        return ExplainResponse(explanations: map)
    }

    // MARK: POST /api/search/ai/posts

    struct AIPostSearchResponse: Content {
        var data: [PostObject]
        var criteria: OllamaService.SearchCriteria
        var warnings: [Warning]
        /// Post id → how close it is to the topics it is about (0…1), the
        /// match % the app shows. The order is `PostRanking`'s, not this.
        var match_scores: [String: Double]
    }

    /// AI search over posts, in the same steps as people search: the LLM
    /// breaks the prompt into elements (`OllamaService.extractPostQuery`),
    /// each topic gets its own vector, then the posts about any of them
    /// (`SearchConcepts.postMatches`), those meeting more of the prompt
    /// first and the most popular first among equals (`PostRanking`).
    static func aiPostSearch(_ req: Request) async throws -> AIPostSearchResponse {
        let b = try req.content.decode(AIBody.self)
        let userQuery = try cleanQuery(b.query)
        guard !userQuery.isEmpty else { throw StatusMessageError(.badRequest, "query is required") }
        if let m = b.mode, !["hobby", "work"].contains(m) {
            throw StatusMessageError(.badRequest, "mode must be hobby or work")
        }
        let db = req.db.sql()
        let cfg = req.ollama
        let log = req.logger

        // Step 2 for posts: the prompt broken into what the posts are about.
        var timer = StepTimer()
        let parsed = await OllamaService.extractPostQuery(cfg, userQuery, logger: log, db: db)
        timer.mark("criteria")
        let mode = b.mode
        let criteria = OllamaService.SearchCriteria(
            intent_en: userQuery, entity_keywords: [], interest_groups: parsed?.topics ?? [], interests: [],
            skills: [], bio_keywords: [], job_title_keywords: [], place_name: parsed?.place, mode: mode)
        func empty(_ code: String, _ value: String? = nil) -> AIPostSearchResponse {
            AIPostSearchResponse(data: [], criteria: criteria, warnings: [Warning(code: code, value: value)], match_scores: [:])
        }

        // One topic per catalogue name in the prompt and per topic the LLM
        // read; without a topic there is nothing to find.
        let concepts = await englishConcepts(
            cfg, SearchConcepts.concepts(prompt: userQuery, criteria: criteria,
                                         entries: try await SearchConcepts.searchEntries(mode: mode, on: db)), logger: log)
        // The place the prompt names, as today's wards, and the posts about it.
        timer.mark("topics")
        var inPlace: Set<String>?
        let placePhrases = [PlaceReader.placePhrase(in: userQuery), parsed?.place].compactMap { $0 }
        if !placePhrases.isEmpty {
            do {
                let home = try await WardStore.provinceCode(named: nil, orOfUser: req.userID, on: db)
                let place = try await PlaceReader.resolve(placePhrases, homeProvince: home, client: HTTPClient.shared, on: db, logger: log)
                if !place.isEmpty { inPlace = try await SearchStore.postsInPlace(place, mode: mode, on: db) }
            } catch { log.warning("Post search place lookup failed: \(error)") }
        }
        timer.mark("place")
        guard !concepts.isEmpty || inPlace != nil else {
            try? await SearchStore.logSearch(userQuery, mode: b.mode, on: db)
            return empty("query_unclear")
        }
        let vectors = await conceptVectors(cfg, concepts, logger: log)
        timer.mark("vectors")
        var perConcept: [[String: Double]] = []
        for (c, v) in zip(concepts, vectors) {
            let hits = try await SearchStore.conceptPosts(c, vector: v, mode: mode,
                                                          min: SearchConcepts.postMin(for: c), on: db)
            perConcept.append(Dictionary(hits.map { ($0.id, $0.sim) }, uniquingKeysWith: max))
        }
        timer.mark("retrieval")
        let best = SearchConcepts.postMatches(perConcept, inPlace: inPlace)
        // The prompt as typed, not the topics read from it: those are the
        // LLM's English ("grilled meat restaurant").
        guard !best.isEmpty else { return empty("no_match", userQuery) }
        let warnings: [Warning] = []

        let visible = try await PostStore.findVisible(Array(best.keys), viewer: req.userID, on: db)
        func key(_ p: PostObject) -> PostRanking.Key {
            PostRanking.Key(criteria: best[p.id]?.criteria ?? 0,
                            engagement: PostRanking.engagement(likes: p.like_count, shares: p.share_count, comments: p.comment_count),
                            match: best[p.id]?.match ?? 0)
        }
        let ranked = visible
            .sorted { PostRanking.comesFirst(key($0), key($1)) }
            .prefix(20)
        timer.mark("rank")
        log.info("ai search timing posts \(timer.summary) results=\(ranked.count)")
        try? await SearchStore.logSearch(userQuery, mode: b.mode, on: db)
        return AIPostSearchResponse(
            data: Array(ranked), criteria: criteria, warnings: warnings,
            match_scores: Dictionary(uniqueKeysWithValues: ranked.map { ($0.id, best[$0.id]?.match ?? 0) })
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
        // No close candidates. The entity may be a new proper noun. Learn it in
        // the background (Wikipedia → interest_entities) so Tier-1 catches it next time.
        selfLearn(name, category: c.entity_type, cfg: cfg, on: db, logger: logger)
        return EntityVecResult(vec: nameVec, suggestion: nil)
    }

    /// Fire-and-forget 3-tier `lookupEntity`. Its Tier-2/Tier-3 side effects
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

    // MARK: hybrid (AI_SEARCH_REVIEW.md, phase S1)

    /// A name this close to words of the prompt is what was asked for, whatever
    /// else the prompt says ("Lý Thảo" → @lythao). Weaker name hits ("Nam" in
    /// "bạn nam") only rank.
    static let strongNameMatch = 0.8
    /// RRF constant: large enough that being 1st vs 3rd in one list matters
    /// less than appearing in two lists.
    static let rrfK = 60.0
    /// A name typed in the prompt is the most explicit signal there is, so the
    /// name ranking counts double: "Lý Thảo" puts @lythao first.
    static let nameWeight = 2.0

    /// The vector legs, entity and general, merged. The whole prompt is never
    /// embedded on its own: "find a friend who likes …" reads close to every
    /// profile, whatever follows it (phase S6).
    static func semanticSearch(_ p: SearchStore.Params, entityVec: [Double]?, generalVec: [Double]?,
                               on db: any SQLDatabase) async throws -> [SearchStore.RawUser] {
        async let entityRows: [SearchStore.RawUser] = {
            guard let ev = entityVec else { return [] }
            var pp = p; pp.queryVector = ev; pp.interestGroups = nil
            return try await SearchStore.vectorSearch(pp, on: db)
        }()
        async let generalRows: [SearchStore.RawUser] = {
            guard let gv = generalVec else { return [] }
            var pp = p; pp.queryVector = gv
            return try await SearchStore.vectorSearch(pp, on: db)
        }()
        return mergeWeighted(try await entityRows, try await generalRows)
    }

    /// Topics the LLM left in another language, put into English before they
    /// are matched (`SearchConcepts.needsEnglish`). A failed translation keeps
    /// the topic as typed.
    static func englishConcepts(_ cfg: OllamaService.Config, _ concepts: [SearchConcepts.Concept],
                                logger: Logger) async -> [SearchConcepts.Concept] {
        await withTaskGroup(of: (Int, SearchConcepts.Concept).self) { group in
            for (i, c) in concepts.enumerated() where SearchConcepts.needsEnglish(c) {
                group.addTask {
                    do {
                        return (i, SearchConcepts.inEnglish(c, translation: try await OllamaService.translateToEnglish(cfg, c.vectorText)))
                    } catch {
                        logger.warning("Topic translation failed: \(error)")
                        return (i, c)
                    }
                }
            }
            var out = concepts
            for await (i, c) in group { out[i] = c }
            return out
        }
    }

    /// Each topic embedded on its own, for the topic gate's post check.
    static func conceptVectors(_ cfg: OllamaService.Config, _ concepts: [SearchConcepts.Concept],
                               logger: Logger) async -> [[Double]?] {
        await withTaskGroup(of: (Int, [Double]?).self) { group in
            for (i, c) in concepts.enumerated() {
                let text = c.vectorText
                group.addTask { (i, await OllamaService.embedQuery(cfg, text, logger: logger)) }
            }
            var out = [[Double]?](repeating: nil, count: concepts.count)
            for await (i, v) in group { out[i] = v }
            return out
        }
    }

    /// Each vector searched on its own; a person keeps their best match.
    static func bestOfVectors(_ p: SearchStore.Params, _ vectors: [[Double]],
                              on db: any SQLDatabase) async throws -> [SearchStore.RawUser] {
        guard !vectors.isEmpty else { return [] }
        var best: [String: SearchStore.RawUser] = [:]
        try await withThrowingTaskGroup(of: [SearchStore.RawUser].self) { group in
            for v in vectors {
                var pp = p; pp.queryVector = v
                let q = pp
                group.addTask { try await SearchStore.vectorSearch(q, on: db) }
            }
            for try await rows in group {
                for u in rows where u.score > (best[u.id]?.score ?? -1) { best[u.id] = u }
            }
        }
        return best.values.sorted { $0.score > $1.score }
    }

    /// What the keyword leg looks for: every concrete term the LLM pulled out.
    static func keywordTerms(_ c: OllamaService.SearchCriteria) -> [String] {
        let all = collectCriteriaTerms(c) + c.interests.filter { $0.trimmingCharacters(in: .whitespaces).count >= 2 }
        return Array(Set(all).filter { $0.count <= 60 }.sorted().prefix(20))
    }

    /// Reciprocal Rank Fusion: each list adds weight / (k + rank) for every id
    /// in it (rank from 1; weight 1 unless given). Ranks, not scores, so lists
    /// scored on different scales (cosine vs text rank) combine fairly.
    static func rrf(_ lists: [[String]], weights: [Double] = []) -> [String: Double] {
        var fused: [String: Double] = [:]
        for (li, list) in lists.enumerated() {
            let w = li < weights.count ? weights[li] : 1
            for (i, id) in list.enumerated() { fused[id, default: 0] += w / (rrfK + Double(i + 1)) }
        }
        return fused
    }

    /// One list from up to four rankings. Meaning (vector), words (full
    /// text), names, and the personal vectors ("like me", "More like @x").
    /// Someone found by more than one rises; `score` becomes the fused one.
    static func fuse(semantic: [SearchStore.RawUser], keyword: [SearchStore.RawUser],
                     personal: [SearchStore.RawUser] = []) -> [SearchStore.RawUser] {
        let text = keyword.filter { $0.retrieval > 0 }.sorted { $0.score > $1.score }.map(\.id)
        let names = keyword.filter { $0.name_match > 0 }.sorted { $0.name_match > $1.name_match }.map(\.id)
        let fused = rrf([semantic.map(\.id), text, names, personal.map(\.id)], weights: [1, 1, nameWeight, 1])
        let semanticRank = Dictionary(uniqueKeysWithValues: semantic.enumerated().map { ($1.id, $0) })

        var byID = Dictionary(keyword.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for u in personal where byID[u.id] == nil { byID[u.id] = u }
        for u in semantic {
            var merged = u
            if let k = byID[u.id] {
                let ev = mergeEvidence(decodeEvidence(u.match_evidence), decodeEvidence(k.match_evidence))
                let enc = (try? JSONCoding.makeEncoder().encode(ev)) ?? Data("[]".utf8)
                merged.match_evidence = String(data: enc, encoding: .utf8) ?? "[]"
                merged.name_match = k.name_match
            }
            byID[u.id] = merged
        }
        return byID.values
            .map { u -> SearchStore.RawUser in var uu = u; uu.score = fused[u.id] ?? 0; return uu }
            .sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                return (semanticRank[$0.id] ?? .max) < (semanticRank[$1.id] ?? .max)
            }
            .prefix(20)
            .map { $0 }
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
                score: u.score, mutual_count: u.mutual_count, match_evidence: evidence,
                distance_km: u.distance_km)
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

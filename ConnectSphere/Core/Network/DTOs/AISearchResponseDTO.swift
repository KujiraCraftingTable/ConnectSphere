import Foundation

struct AISearchCriteriaDTO: Decodable {
    let entity_type:        String?
    let entity_name:        String?
    let entity_keywords:    [String]
    let interests:          [String]   // flattened from interest_groups [[String]]
    let skills:             [String]
    let bio_keywords:       [String]
    let job_title_keywords: [String]
    let location:           String?

    private enum CodingKeys: String, CodingKey {
        case entity_type, entity_name, entity_keywords
        case interest_groups
        case skills, bio_keywords, job_title_keywords, location
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        entity_type        = try c.decodeIfPresent(String.self,   forKey: .entity_type)
        entity_name        = try c.decodeIfPresent(String.self,   forKey: .entity_name)
        entity_keywords    = (try? c.decode([String].self,        forKey: .entity_keywords))    ?? []
        skills             = (try? c.decode([String].self,        forKey: .skills))             ?? []
        bio_keywords       = (try? c.decode([String].self,        forKey: .bio_keywords))       ?? []
        job_title_keywords = (try? c.decode([String].self,        forKey: .job_title_keywords)) ?? []
        location           = try c.decodeIfPresent(String.self,   forKey: .location)
        // Flatten [[String]] → [String], deduplicated
        let groups         = (try? c.decode([[String]].self,      forKey: .interest_groups))    ?? []
        interests          = Array(NSOrderedSet(array: groups.flatMap { $0 })) as? [String] ?? groups.flatMap { $0 }
    }
}

/// A "match reason" in the mini CV — pre-built by the backend from a chunk/community, no LLM call.
/// Posts are already grouped by topic on the backend: postCount posts, newest/oldest timestamps.
struct MatchEvidenceDTO: Decodable, Hashable {
    let type:           String     // "profile" | "post" | "community"
    let topic:          String?
    let similarity:     Double?
    let matchedTerms:   [String]
    let postCount:      Int?
    let latestPostAt:   Date?
    let oldestPostAt:   Date?
    let communityName:  String?

    private enum CodingKeys: String, CodingKey {
        case type, topic, similarity
        case matchedTerms  = "matched_terms"
        case postCount     = "post_count"
        case latestPostAt  = "latest_post_at"
        case oldestPostAt  = "oldest_post_at"
        case communityName = "community_name"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type          = (try? c.decode(String.self, forKey: .type)) ?? "profile"
        topic         = try c.decodeIfPresent(String.self, forKey: .topic)
        similarity    = try c.decodeIfPresent(Double.self, forKey: .similarity)
        matchedTerms  = (try? c.decode([String].self, forKey: .matchedTerms)) ?? []
        postCount     = try? c.decodeIfPresent(Int.self, forKey: .postCount)
        latestPostAt  = try? c.decodeIfPresent(Date.self, forKey: .latestPostAt)
        oldestPostAt  = try? c.decodeIfPresent(Date.self, forKey: .oldestPostAt)
        communityName = try c.decodeIfPresent(String.self, forKey: .communityName)
    }
}

/// A canonical candidate for a gray-zone keyword (0.6–0.8): "did you mean …?"
struct EntityCandidateDTO: Decodable, Identifiable {
    let entity_id:      String
    let canonical_name: String
    var id: String { entity_id }
}

struct EntitySuggestionDTO: Decodable, Identifiable {
    let keyword:    String
    let candidates: [EntityCandidateDTO]
    var id: String { keyword }
}

/// Something in the query the AI couldn't understand or apply (e.g. a venue it
/// couldn't place). Backend sends a stable `code` plus optional `value` rather
/// than prose, so the text is localized here in the app, not hardcoded server-side.
struct SearchWarningDTO: Decodable {
    let code:  String
    let value: String?
}

struct AISearchResponseDTO: Decodable {
    let data:      [UserDTO]
    let criteria:  AISearchCriteriaDTO
    let entity_suggestions: [EntitySuggestionDTO]
    let warnings:  [SearchWarningDTO]

    private enum CodingKeys: String, CodingKey {
        case data, criteria, entity_suggestions, warnings
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        data      = try c.decode([UserDTO].self, forKey: .data)
        criteria  = try c.decode(AISearchCriteriaDTO.self, forKey: .criteria)
        // New field — still decodes fine against an older backend or an empty response
        entity_suggestions = (try? c.decode([EntitySuggestionDTO].self, forKey: .entity_suggestions)) ?? []
        warnings           = (try? c.decode([SearchWarningDTO].self, forKey: .warnings)) ?? []
    }
}

struct SearchSuggestionsDTO: Decodable {
    let suggestions: [String]
}

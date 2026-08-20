import Foundation

struct AISearchCriteriaDTO: Decodable {
    let entity_type:        String?
    let entity_name:        String?
    let entity_keywords:    [String]
    let interests:          [String]   // flattened từ interest_groups [[String]]
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

/// Một "lý do khớp" trong mini CV — backend build sẵn từ chunk/community, không gọi LLM.
/// Post đã được backend gộp theo topic: postCount bài, mốc thời gian mới/cũ nhất.
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

/// Một ứng viên canonical cho keyword vùng xám (0.6–0.8): "ý bạn là …?"
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

struct AISearchResponseDTO: Decodable {
    let data:      [UserDTO]
    let criteria:  AISearchCriteriaDTO
    let reasoning: String
    let tips:      String
    let entity_suggestions: [EntitySuggestionDTO]

    private enum CodingKeys: String, CodingKey {
        case data, criteria, reasoning, tips, entity_suggestions
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        data      = try c.decode([UserDTO].self, forKey: .data)
        criteria  = try c.decode(AISearchCriteriaDTO.self, forKey: .criteria)
        reasoning = (try? c.decode(String.self, forKey: .reasoning)) ?? ""
        tips      = (try? c.decode(String.self, forKey: .tips)) ?? ""
        // Field mới — backend cũ hoặc response rỗng vẫn decode được
        entity_suggestions = (try? c.decode([EntitySuggestionDTO].self, forKey: .entity_suggestions)) ?? []
    }
}

struct SearchSuggestionsDTO: Decodable {
    let suggestions: [String]
}

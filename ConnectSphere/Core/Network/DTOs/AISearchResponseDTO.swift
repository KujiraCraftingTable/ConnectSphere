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

struct AISearchResponseDTO: Decodable {
    let data:      [UserDTO]
    let criteria:  AISearchCriteriaDTO
    let reasoning: String
    let tips:      String
}

struct SearchSuggestionsDTO: Decodable {
    let suggestions: [String]
}

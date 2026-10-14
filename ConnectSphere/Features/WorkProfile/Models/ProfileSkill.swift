import Foundation

/// A skill on a Work profile, with who vouched for it.
struct ProfileSkill: Identifiable, Decodable, Hashable {
    let id: Int
    let skill: String
    var endorsementCount: Int
    var endorsedByMe: Bool
    var topEndorsers: [Endorser]

    struct Endorser: Identifiable, Decodable, Hashable {
        let id: String
        let displayName: String
        let avatarUrl: String?
        let avatarColor: String?
        enum CodingKeys: String, CodingKey {
            case id
            case displayName = "display_name"
            case avatarUrl = "avatar_url"
            case avatarColor = "avatar_color"
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, skill
        case endorsementCount = "endorsement_count"
        case endorsedByMe = "endorsed_by_me"
        case topEndorsers = "top_endorsers"
    }
}

/// The skills list and whether the viewer may endorse them.
struct ProfileSkills: Decodable {
    var data: [ProfileSkill]
    var canEndorse: Bool
    enum CodingKeys: String, CodingKey {
        case data
        case canEndorse = "can_endorse"
    }
}

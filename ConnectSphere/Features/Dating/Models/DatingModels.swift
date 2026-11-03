import Foundation

/// Who someone wants to be shown in Dating.
enum DatingInterest: String, CaseIterable, Codable {
    case men, women, everyone

    var label: String {
        switch self {
        case .men: return "Men"
        case .women: return "Women"
        case .everyone: return "Everyone"
        }
    }
}

/// "Do you have kids?" — optional, shown on the profile.
enum DatingKids: String, CaseIterable, Codable {
    case no, yes
    case preferNot = "prefer_not"

    var label: String {
        switch self {
        case .no: return "No, I don't have kids"
        case .yes: return "Yes, I have kids"
        case .preferNot: return "Prefer not to say"
        }
    }

    /// The line on a card; nil when it isn't shown.
    var cardLine: String? {
        switch self {
        case .no: return "Doesn't have kids"
        case .yes: return "Has kids"
        case .preferNot: return nil
        }
    }
}

/// Name, age and gender from the account — the setup's "Your basics" step.
struct DatingBasics: Decodable {
    let displayName: String
    let age: Int?
    let gender: String

    enum CodingKeys: String, CodingKey {
        case age, gender
        case displayName = "display_name"
    }
}

/// `GET /dating/me`: whether Dating is open to this account, and its profile.
struct DatingStatus: Decodable {
    /// "open" or "locked" (under 16, or no birthday on the account).
    let access: String
    let minAge: Int
    /// "teen" (16–17) or "adult" (18+); nil while locked.
    let band: String?
    var profile: DatingProfile?
    let me: DatingBasics?

    var isLocked: Bool { access != "open" }
    var isTeen: Bool { band == "teen" }

    enum CodingKeys: String, CodingKey {
        case access, band, profile, me
        case minAge = "min_age"
    }
}

/// The signed-in user's own dating profile.
struct DatingProfile: Codable, Equatable {
    var bio: String
    var interestedIn: DatingInterest
    var minAge: Int
    var maxAge: Int
    var maxDistanceKm: Int?
    var heightCm: Int?
    var hasKids: DatingKids?
    var city: String
    var latitude: Double
    var longitude: Double
    var isActive: Bool
    /// Bare `/uploads/…` paths, cover first.
    var photos: [String]

    enum CodingKeys: String, CodingKey {
        case bio, city, latitude, longitude, photos
        case interestedIn = "interested_in"
        case minAge = "min_age"
        case maxAge = "max_age"
        case maxDistanceKm = "max_distance_km"
        case heightCm = "height_cm"
        case hasKids = "has_kids"
        case isActive = "is_active"
    }
}

/// Another person as Dating shows them: Hobby name, age, city and their
/// dating photos — never their username or main profile.
struct DatingCard: Decodable, Identifiable, Equatable {
    let id: String
    let displayName: String
    let avatarColor: String?
    let age: Int
    let city: String
    let bio: String
    let heightCm: Int?
    let hasKids: DatingKids?
    let distanceKm: Int
    let photos: [String]
    let sharedInterests: [String]

    enum CodingKeys: String, CodingKey {
        case id, age, city, bio, photos
        case displayName = "display_name"
        case avatarColor = "avatar_color"
        case heightCm = "height_cm"
        case hasKids = "has_kids"
        case distanceKm = "distance_km"
        case sharedInterests = "shared_interests"
    }
}

/// Someone in "Likes you".
struct DatingLiker: Decodable, Identifiable {
    let card: DatingCard
    let likedAt: Date

    var id: String { card.id }

    enum CodingKeys: String, CodingKey {
        case card
        case likedAt = "liked_at"
    }
}

struct DatingMatch: Decodable, Identifiable {
    let id: String
    let conversationId: String?
    let matchedAt: Date
    let person: DatingCard

    enum CodingKeys: String, CodingKey {
        case id, person
        case conversationId = "conversation_id"
        case matchedAt = "matched_at"
    }
}

/// The answer to a like or a pass.
struct DatingLikeResult: Decodable {
    let matched: Bool
    let matchId: String?
    let conversationId: String?
    /// True only for the like that made the match.
    let isNew: Bool

    enum CodingKeys: String, CodingKey {
        case matched
        case matchId = "match_id"
        case conversationId = "conversation_id"
        case isNew = "is_new"
    }
}

extension Notification.Name {
    /// A Dating match was made or ended — the inbox's Dating button re-checks.
    static let datingMatchesChanged = Notification.Name("datingMatchesChanged")
}

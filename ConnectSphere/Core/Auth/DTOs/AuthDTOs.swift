import Foundation

struct AuthResponse: Decodable {
    let token: String
    let user: AuthUserDTO
    let isNewUser: Bool
    enum CodingKeys: String, CodingKey {
        case token, user, isNewUser = "is_new_user"
    }
}

struct MeResponse: Decodable {
    let user: AuthUserDTO
}

struct AuthUserDTO: Decodable {
    let id: String
    let username: String
    let displayName: String
    let bio: String?
    let avatarColor: String
    let avatarUrl: String?
    let jobTitle: String?
    let company: String?
    let location: String?
    let gender: String?
    let defaultMode: String
    let followerCount: Int
    let followingCount: Int
    let postCount: Int
    let isSetup: Bool
    let interests: [String]
    let skills: [String]

    enum CodingKeys: String, CodingKey {
        case id, username, bio, location, gender, interests, skills
        case displayName    = "display_name"
        case avatarColor    = "avatar_color"
        case avatarUrl      = "avatar_url"
        case jobTitle       = "job_title"
        case company
        case defaultMode    = "default_mode"
        case followerCount  = "follower_count"
        case followingCount = "following_count"
        case postCount      = "post_count"
        case isSetup        = "is_setup"
    }

    func toUserProfile() -> UserProfile {
        UserProfile(
            id: id, name: displayName, username: username,
            avatarColor: avatarColor, avatarUrl: avatarUrl, bio: bio ?? "",
            jobTitle: jobTitle, company: company,
            skills: skills, interests: interests,
            location: location,
            gender: gender,
            followerCount: followerCount,
            followingCount: followingCount,
            postCount: postCount
        )
    }
}

struct OnboardingForm: Encodable {
    var username: String = ""
    var display_name: String = ""
    var dob: String = ""
    var bio: String = ""
    var location: String = ""
    var gender: String = "other"
    var default_mode: String = "friend"
    var job_title: String = ""
    var company: String = ""
    var interests: [String] = []
    var skills: [String] = []
}

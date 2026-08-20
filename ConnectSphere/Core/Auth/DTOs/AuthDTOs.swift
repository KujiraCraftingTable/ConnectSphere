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
    let coverUrl: String?
    let jobTitle: String?
    let company: String?
    let location: String?
    let gender: String?
    let email: String?
    let hasPassword: Bool?
    let age: Int?
    let dob: String?
    let dobVisibility: String?
    let defaultMode: String
    let followerCount: Int
    let followingCount: Int
    let postCount: Int
    let isSetup: Bool
    let hobbySetup: Bool?
    let workSetup: Bool?
    let interests: [String]
    let skills: [String]

    enum CodingKeys: String, CodingKey {
        case id, username, bio, location, gender, email, interests, skills, age, dob
        case hasPassword    = "has_password"
        case dobVisibility  = "dob_visibility"
        case displayName    = "display_name"
        case avatarColor    = "avatar_color"
        case avatarUrl      = "avatar_url"
        case coverUrl       = "cover_url"
        case jobTitle       = "job_title"
        case company
        case defaultMode    = "default_mode"
        case followerCount  = "follower_count"
        case followingCount = "following_count"
        case postCount      = "post_count"
        case isSetup        = "is_setup"
        case hobbySetup     = "hobby_setup"
        case workSetup      = "work_setup"
    }

    func toUserProfile() -> UserProfile {
        UserProfile(
            id: id, name: displayName, username: username,
            avatarColor: avatarColor, avatarUrl: avatarUrl, coverUrl: coverUrl, bio: bio ?? "",
            jobTitle: jobTitle, company: company,
            skills: skills, interests: interests,
            location: location,
            gender: gender,
            hobbySetup: hobbySetup ?? false,
            workSetup: workSetup ?? false,
            email: email,
            hasPassword: hasPassword ?? false,
            age: age,
            dob: dob,
            dobVisibility: dobVisibility,
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
    var dob_visibility: String = "private"
    var bio: String = ""
    var location: String = ""
    var gender: String = "other"
    var default_mode: String = "hobby"
    var job_title: String = ""
    var company: String = ""
    var interests: [String] = []
    var skills: [String] = []
}

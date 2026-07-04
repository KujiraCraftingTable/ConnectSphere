import Foundation

struct UserDTO: Decodable {
    let id: String
    let username: String
    let displayName: String
    let bio: String?
    let avatarColor: String
    let avatarUrl: String?
    let location: String?
    let gender: String?
    let jobTitle: String?
    let company: String?
    let defaultMode: String?
    let followerCount: Int
    let followingCount: Int
    let postCount: Int
    let interests: [String]
    let skills: [String]
    let score: Double?

    enum CodingKeys: String, CodingKey {
        case id, username, bio, location, gender, company, interests, skills, score
        case displayName    = "display_name"
        case avatarColor    = "avatar_color"
        case avatarUrl      = "avatar_url"
        case jobTitle       = "job_title"
        case defaultMode    = "default_mode"
        case followerCount  = "follower_count"
        case followingCount = "following_count"
        case postCount      = "post_count"
    }

    func toUserProfile() -> UserProfile {
        UserProfile(
            id:             id,
            name:           displayName,
            username:       username,
            avatarColor:    avatarColor,
            avatarUrl:      avatarUrl,
            bio:            bio ?? "",
            jobTitle:       jobTitle,
            company:        company,
            skills:         skills,
            interests:      interests,
            location:       location,
            gender:         gender,
            followerCount:  followerCount,
            followingCount: followingCount,
            postCount:      postCount,
            score:          score
        )
    }
}

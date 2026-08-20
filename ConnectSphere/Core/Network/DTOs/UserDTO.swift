import Foundation

struct UserDTO: Decodable {
    let id: String
    let username: String
    let displayName: String
    let bio: String?
    let avatarColor: String
    let avatarUrl: String?
    let coverUrl: String?
    let location: String?
    let gender: String?
    let email: String?        // chỉ có trong response của chính chủ (PATCH /users/me)
    let hasPassword: Bool?    // như trên
    let age: Int?              // tuổi hiển thị — server null khi dob_visibility = private
    let jobTitle: String?
    let company: String?
    let defaultMode: String?
    let hobbySetup: Bool?
    let workSetup: Bool?
    let followerCount: Int
    let followingCount: Int
    let postCount: Int
    let connectionCount: Int?   // số kết nối accepted theo mode — chỉ có khi fetch profile
    let mutualCount: Int?       // số bạn/kết nối chung với viewer — có trong search/list
    let interests: [String]
    let skills: [String]
    let score: Double?
    let matchEvidence: [MatchEvidenceDTO]?   // chỉ có trong response AI search (mini CV)

    enum CodingKeys: String, CodingKey {
        case id, username, bio, location, gender, email, company, interests, skills, score, age
        case hasPassword     = "has_password"
        case displayName     = "display_name"
        case avatarColor     = "avatar_color"
        case avatarUrl       = "avatar_url"
        case coverUrl        = "cover_url"
        case jobTitle        = "job_title"
        case defaultMode     = "default_mode"
        case hobbySetup      = "hobby_setup"
        case workSetup       = "work_setup"
        case followerCount   = "follower_count"
        case followingCount  = "following_count"
        case postCount       = "post_count"
        case connectionCount = "connection_count"
        case mutualCount     = "mutual_count"
        case matchEvidence   = "match_evidence"
    }

    func toUserProfile() -> UserProfile {
        UserProfile(
            id:             id,
            name:           displayName,
            username:       username,
            avatarColor:    avatarColor,
            avatarUrl:      avatarUrl,
            coverUrl:       coverUrl,
            bio:            bio ?? "",
            jobTitle:       jobTitle,
            company:        company,
            skills:         skills,
            interests:      interests,
            location:       location,
            gender:         gender,
            hobbySetup:     hobbySetup ?? false,
            workSetup:      workSetup ?? false,
            email:          email,
            hasPassword:    hasPassword ?? false,
            age:            age,
            followerCount:  followerCount,
            followingCount: followingCount,
            postCount:      postCount,
            connectionCount: connectionCount ?? 0,
            mutualCount:    mutualCount ?? 0,
            score:          score
        )
    }
}

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
    let email: String?        // only present in the owner's own response (PATCH /users/me)
    let hasPassword: Bool?    // same as above
    let age: Int?              // displayed age — the server returns null when dob_visibility = private
    /// The owner's own response only (PATCH /users/me). Without it, a saved
    /// profile lost its date of birth and Edit profile showed "20 years ago".
    let dob: String?
    let dobVisibility: String?
    /// The persona's "See my other profile" switch; missing → on.
    let linksOtherMode: Bool?
    /// Owner's own response only (PATCH /users/me).
    let emailVerified: Bool?
    let languages: [String]?
    let relationshipStatus: String?
    let isLocked: Bool?
    let canView: Bool?
    let jobTitle: String?
    let company: String?
    let defaultMode: String?
    let hobbySetup: Bool?
    let workSetup: Bool?
    let followerCount: Int
    let followingCount: Int
    let postCount: Int
    let connectionCount: Int?   // number of accepted connections for the mode — only present when fetching a profile
    let mutualCount: Int?       // number of mutual friends/connections with the viewer — present in search/list
    let interests: [String]
    let skills: [String]
    let score: Double?
    let matchEvidence: [MatchEvidenceDTO]?   // only present in the AI search response (mini CV)

    enum CodingKeys: String, CodingKey {
        case id, username, bio, location, gender, email, company, interests, skills, score, age, dob
        case dobVisibility   = "dob_visibility"
        case linksOtherMode  = "links_other_mode"
        case emailVerified   = "email_verified"
        case languages
        case relationshipStatus = "relationship_status"
        case isLocked        = "is_locked"
        case canView         = "can_view"
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
            linksOtherMode: linksOtherMode ?? true,
            emailVerified:  emailVerified ?? false,
            languages:      languages ?? [],
            relationshipStatus: relationshipStatus,
            isLocked:       isLocked ?? false,
            canView:        canView ?? true,
            age:            age,
            dob:            dob,
            dobVisibility:  dobVisibility,
            followerCount:  followerCount,
            followingCount: followingCount,
            postCount:      postCount,
            connectionCount: connectionCount ?? 0,
            mutualCount:    mutualCount ?? 0,
            score:          score
        )
    }
}

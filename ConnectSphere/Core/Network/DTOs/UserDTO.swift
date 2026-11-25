import Foundation

struct UserDTO: Decodable {
    let id: String
    let username: String
    let displayName: String
    let bio: String?
    let bioFormat: String?
    let avatarColor: String
    let avatarUrl: String?
    let coverUrl: String?
    let location: String?
    let gender: String?
    let email: String?        // only present in the owner's own response (PATCH /users/me)
    let hasPassword: Bool?    // same as above
    let age: Int?              // displayed age, the server returns null when dob_visibility = private
    /// The owner's own response only (PATCH /users/me). Without it, a saved
    /// profile lost its date of birth and Edit profile showed "20 years ago".
    let dob: String?
    let dobVisibility: String?
    /// Owner's own responses only: birthday changes still allowed (2 per account).
    let dobChangesLeft: Int?
    /// The persona's "See my other profile" switch; missing → on.
    let linksOtherMode: Bool?
    /// Owner's own response only (PATCH /users/me).
    let emailVerified: Bool?
    let twoFactorEnabled: Bool?
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
    let connectionCount: Int?   // number of accepted connections for the mode. Only present when fetching a profile
    let mutualCount: Int?       // number of mutual friends/connections with the viewer. Present in search/list
    let interests: [String]
    let skills: [String]
    let score: Double?
    let matchEvidence: [MatchEvidenceDTO]?   // only present in the AI search response (mini CV)
    /// AI search with a radius only (rounded up to 5 km).
    let distanceKm: Int?
    let isOfficial: Bool?
    /// The company this person is verified HR for; Work views only (server migration 126).
    let hrCompany: String?
    /// The owner's own response only: the private home ward and its province.
    let wardId: String?
    let wardProvinceCode: String?

    // MARK: - Coding keys
    enum CodingKeys: String, CodingKey {
        case bioFormat = "bio_format"
        case id, username, bio, location, gender, email, company, interests, skills, score, age, dob
        case dobVisibility   = "dob_visibility"
        case dobChangesLeft  = "dob_changes_left"
        case linksOtherMode  = "links_other_mode"
        case emailVerified   = "email_verified"
        case twoFactorEnabled = "two_factor_enabled"
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
        case distanceKm      = "distance_km"
        case isOfficial      = "is_official"
        case hrCompany       = "hr_company"
        case wardId          = "ward_id"
        case wardProvinceCode = "ward_province_code"
    }

    // MARK: - Mapping
    func toUserProfile() -> UserProfile {
        UserProfile(
            id:             id,
            name:           displayName,
            username:       username,
            avatarColor:    avatarColor,
            avatarUrl:      avatarUrl,
            coverUrl:       coverUrl,
            bio:            bio ?? "",
            bioFormat:      bioFormat,
            jobTitle:       jobTitle,
            company:        company,
            skills:         skills,
            interests:      interests,
            location:       location,
            wardId:         wardId,
            wardProvinceCode: wardProvinceCode,
            gender:         gender,
            hobbySetup:     hobbySetup ?? false,
            workSetup:      workSetup ?? false,
            email:          email,
            hasPassword:    hasPassword ?? false,
            linksOtherMode: linksOtherMode ?? true,
            emailVerified:  emailVerified ?? false,
            twoFactorEnabled: twoFactorEnabled ?? false,
            languages:      languages ?? [],
            relationshipStatus: relationshipStatus,
            isLocked:       isLocked ?? false,
            canView:        canView ?? true,
            age:            age,
            dob:            dob,
            dobVisibility:  dobVisibility,
            dobChangesLeft: dobChangesLeft,
            followerCount:  followerCount,
            followingCount: followingCount,
            postCount:      postCount,
            connectionCount: connectionCount ?? 0,
            mutualCount:    mutualCount ?? 0,
            score:          score,
            distanceKm:     distanceKm,
            isOfficial:     isOfficial ?? false,
            hrCompany:      hrCompany
        )
    }
}

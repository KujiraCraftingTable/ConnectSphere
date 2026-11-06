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
    let bioFormat: String?
    let avatarColor: String
    let avatarUrl: String?
    let coverUrl: String?
    let jobTitle: String?
    let company: String?
    let location: String?
    let gender: String?
    let email: String?
    let hasPassword: Bool?
    let allowFriendRequests: Bool?
    let showInSuggestions: Bool?
    let linksOtherMode: Bool?
    let emailVerified: Bool?
    let twoFactorEnabled: Bool?
    let languages: [String]?
    let relationshipStatus: String?
    let isLocked: Bool?
    let age: Int?
    let dob: String?
    let dobVisibility: String?
    /// Birthday changes still allowed (2 per account).
    let dobChangesLeft: Int?
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
        case bioFormat = "bio_format"
        case id, username, bio, location, gender, email, interests, skills, age, dob
        case hasPassword    = "has_password"
        case allowFriendRequests = "allow_friend_requests"
        case showInSuggestions = "show_in_suggestions"
        case linksOtherMode = "links_other_mode"
        case emailVerified = "email_verified"
        case twoFactorEnabled = "two_factor_enabled"
        case languages
        case relationshipStatus = "relationship_status"
        case isLocked = "is_locked"
        case dobVisibility  = "dob_visibility"
        case dobChangesLeft = "dob_changes_left"
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

    // A pre-onboarding /auth/me (or a Google first-login) can omit half of
    // these. Decode leniently so login / auto-login never fails outright. A
    // missing displayName/defaultMode/counts just gets a sensible default.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id             = try c.decode(String.self, forKey: .id)
        username       = try c.decodeIfPresent(String.self, forKey: .username) ?? ""
        displayName    = try c.decodeIfPresent(String.self, forKey: .displayName) ?? ""
        bio            = try c.decodeIfPresent(String.self, forKey: .bio)
        bioFormat      = try c.decodeIfPresent(String.self, forKey: .bioFormat)
        avatarColor    = try c.decodeIfPresent(String.self, forKey: .avatarColor) ?? "#7F5AF0"
        avatarUrl      = try c.decodeIfPresent(String.self, forKey: .avatarUrl)
        coverUrl       = try c.decodeIfPresent(String.self, forKey: .coverUrl)
        jobTitle       = try c.decodeIfPresent(String.self, forKey: .jobTitle)
        company        = try c.decodeIfPresent(String.self, forKey: .company)
        location       = try c.decodeIfPresent(String.self, forKey: .location)
        gender         = try c.decodeIfPresent(String.self, forKey: .gender)
        email          = try c.decodeIfPresent(String.self, forKey: .email)
        hasPassword    = try c.decodeIfPresent(Bool.self, forKey: .hasPassword)
        allowFriendRequests = try c.decodeIfPresent(Bool.self, forKey: .allowFriendRequests)
        showInSuggestions = try c.decodeIfPresent(Bool.self, forKey: .showInSuggestions)
        linksOtherMode = try c.decodeIfPresent(Bool.self, forKey: .linksOtherMode)
        emailVerified = try c.decodeIfPresent(Bool.self, forKey: .emailVerified)
        twoFactorEnabled = try c.decodeIfPresent(Bool.self, forKey: .twoFactorEnabled)
        languages = try c.decodeIfPresent([String].self, forKey: .languages)
        relationshipStatus = try c.decodeIfPresent(String.self, forKey: .relationshipStatus)
        isLocked = try c.decodeIfPresent(Bool.self, forKey: .isLocked)
        age            = try c.decodeIfPresent(Int.self, forKey: .age)
        dob            = try c.decodeIfPresent(String.self, forKey: .dob)
        dobVisibility  = try c.decodeIfPresent(String.self, forKey: .dobVisibility)
        dobChangesLeft = try c.decodeIfPresent(Int.self, forKey: .dobChangesLeft)
        defaultMode    = try c.decodeIfPresent(String.self, forKey: .defaultMode) ?? "hobby"
        followerCount  = try c.decodeIfPresent(Int.self, forKey: .followerCount) ?? 0
        followingCount = try c.decodeIfPresent(Int.self, forKey: .followingCount) ?? 0
        postCount      = try c.decodeIfPresent(Int.self, forKey: .postCount) ?? 0
        isSetup        = try c.decodeIfPresent(Bool.self, forKey: .isSetup) ?? false
        hobbySetup     = try c.decodeIfPresent(Bool.self, forKey: .hobbySetup)
        workSetup      = try c.decodeIfPresent(Bool.self, forKey: .workSetup)
        interests      = try c.decodeIfPresent([String].self, forKey: .interests) ?? []
        skills         = try c.decodeIfPresent([String].self, forKey: .skills) ?? []
    }

    func toUserProfile() -> UserProfile {
        UserProfile(
            id: id, name: displayName, username: username,
            avatarColor: avatarColor, avatarUrl: avatarUrl, coverUrl: coverUrl, bio: bio ?? "", bioFormat: bioFormat,
            jobTitle: jobTitle, company: company,
            skills: skills, interests: interests,
            location: location,
            gender: gender,
            hobbySetup: hobbySetup ?? false,
            workSetup: workSetup ?? false,
            email: email,
            hasPassword: hasPassword ?? false,
            allowFriendRequests: allowFriendRequests ?? true,
            showInSuggestions: showInSuggestions ?? true,
            linksOtherMode: linksOtherMode ?? true,
            emailVerified: emailVerified ?? false,
            twoFactorEnabled: twoFactorEnabled ?? false,
            languages: languages ?? [],
            relationshipStatus: relationshipStatus,
            isLocked: isLocked ?? false,
            age: age,
            dob: dob,
            dobVisibility: dobVisibility,
            dobChangesLeft: dobChangesLeft,
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

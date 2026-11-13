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
    let wardId: String?
    let wardProvinceCode: String?
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
    /// A moderation restriction runs until then: no posting, commenting or joining.
    let restrictedUntil: Date?
    /// Each mode's own restriction (server migration 125); one never pauses the other.
    let hobbyRestrictedUntil: Date?
    let workRestrictedUntil: Date?
    let age: Int?
    let dob: String?
    let dobVisibility: String?
    /// Birthday changes still allowed (2 per account).
    let dobChangesLeft: Int?
    /// The @username can't change again until then; nil when it can now.
    let usernameNextChangeAt: Date?
    let defaultMode: String
    let followerCount: Int
    let followingCount: Int
    let postCount: Int
    /// You are the official @connectsphere account, the app's only admin.
    let isOfficial: Bool
    let isSetup: Bool
    let hobbySetup: Bool?
    let workSetup: Bool?
    let interests: [String]
    let skills: [String]
    /// The account's palette ids per mode (ThemeManager).
    let hobbyTheme: String?
    let workTheme: String?

    var accountTheme: AccountTheme { AccountTheme(userID: id, hobby: hobbyTheme, work: workTheme) }

    enum CodingKeys: String, CodingKey {
        case bioFormat = "bio_format"
        case id, username, bio, location, gender, email, interests, skills, age, dob
        case wardId         = "ward_id"
        case wardProvinceCode = "ward_province_code"
        case hasPassword    = "has_password"
        case allowFriendRequests = "allow_friend_requests"
        case showInSuggestions = "show_in_suggestions"
        case linksOtherMode = "links_other_mode"
        case emailVerified = "email_verified"
        case twoFactorEnabled = "two_factor_enabled"
        case languages
        case relationshipStatus = "relationship_status"
        case isLocked = "is_locked"
        case restrictedUntil = "restricted_until"
        case hobbyRestrictedUntil = "hobby_restricted_until"
        case workRestrictedUntil = "work_restricted_until"
        case dobVisibility  = "dob_visibility"
        case dobChangesLeft = "dob_changes_left"
        case usernameNextChangeAt = "username_next_change_at"
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
        case isOfficial     = "is_official"
        case isSetup        = "is_setup"
        case hobbySetup     = "hobby_setup"
        case workSetup      = "work_setup"
        case hobbyTheme     = "hobby_theme"
        case workTheme      = "work_theme"
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
        wardId         = try c.decodeIfPresent(String.self, forKey: .wardId)
        wardProvinceCode = try c.decodeIfPresent(String.self, forKey: .wardProvinceCode)
        gender        = try c.decodeIfPresent(String.self, forKey: .gender)
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
        // Lenient: the cached copy may store dates differently from the server.
        restrictedUntil = (try? c.decodeIfPresent(Date.self, forKey: .restrictedUntil)) ?? nil
        hobbyRestrictedUntil = (try? c.decodeIfPresent(Date.self, forKey: .hobbyRestrictedUntil)) ?? nil
        workRestrictedUntil = (try? c.decodeIfPresent(Date.self, forKey: .workRestrictedUntil)) ?? nil
        age            = try c.decodeIfPresent(Int.self, forKey: .age)
        dob            = try c.decodeIfPresent(String.self, forKey: .dob)
        dobVisibility  = try c.decodeIfPresent(String.self, forKey: .dobVisibility)
        dobChangesLeft = try c.decodeIfPresent(Int.self, forKey: .dobChangesLeft)
        usernameNextChangeAt = (try? c.decodeIfPresent(Date.self, forKey: .usernameNextChangeAt)) ?? nil
        defaultMode    = try c.decodeIfPresent(String.self, forKey: .defaultMode) ?? "hobby"
        followerCount  = try c.decodeIfPresent(Int.self, forKey: .followerCount) ?? 0
        followingCount = try c.decodeIfPresent(Int.self, forKey: .followingCount) ?? 0
        postCount      = try c.decodeIfPresent(Int.self, forKey: .postCount) ?? 0
        isOfficial     = try c.decodeIfPresent(Bool.self, forKey: .isOfficial) ?? false
        isSetup        = try c.decodeIfPresent(Bool.self, forKey: .isSetup) ?? false
        hobbySetup     = try c.decodeIfPresent(Bool.self, forKey: .hobbySetup)
        workSetup      = try c.decodeIfPresent(Bool.self, forKey: .workSetup)
        interests      = try c.decodeIfPresent([String].self, forKey: .interests) ?? []
        skills         = try c.decodeIfPresent([String].self, forKey: .skills) ?? []
        hobbyTheme     = try c.decodeIfPresent(String.self, forKey: .hobbyTheme)
        workTheme      = try c.decodeIfPresent(String.self, forKey: .workTheme)
    }

    func toUserProfile() -> UserProfile {
        UserProfile(
            id: id, name: displayName, username: username,
            avatarColor: avatarColor, avatarUrl: avatarUrl, coverUrl: coverUrl, bio: bio ?? "", bioFormat: bioFormat,
            jobTitle: jobTitle, company: company,
            skills: skills, interests: interests,
            location: location,
            wardId: wardId,
            wardProvinceCode: wardProvinceCode,
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
            usernameNextChangeAt: usernameNextChangeAt,
            followerCount: followerCount,
            followingCount: followingCount,
            postCount: postCount,
            isOfficial: isOfficial
        )
    }
}

struct OnboardingForm: Encodable {
    var username: String = ""
    var display_name: String = ""
    var dob: String = ""
    var dob_visibility: String = "private"
    var bio: String = ""
    /// Required. The server sets the public location (its province) from it.
    var ward_id: String = ""
    var gender: String = "other"
    var default_mode: String = "hobby"
    var job_title: String = ""
    var company: String = ""
    var interests: [String] = []
    var skills: [String] = []
    /// `LegalDocs.version`, set when the person ticks the Terms/Privacy box.
    var accepted_policy_version: String?
}

extension AuthUserDTO {
    /// Each restricted mode and when it ends. An older server sends one
    /// account-wide date, which then applies to both.
    var restrictions: [AppMode: Date] {
        if hobbyRestrictedUntil == nil && workRestrictedUntil == nil, let all = restrictedUntil {
            return [.hobby: all, .work: all]
        }
        var r: [AppMode: Date] = [:]
        r[.hobby] = hobbyRestrictedUntil
        r[.work] = workRestrictedUntil
        return r
    }
}

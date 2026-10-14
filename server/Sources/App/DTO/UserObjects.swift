import Vapor

/// Shared column set for `userModel.findAll` / `findById`
/// (`backend/src/models/userModel.js` `userSelect`). `interests`/`skills` via
/// `array_agg` (same sorted DISTINCT output as Node's `json_agg(DISTINCT …)`).
struct UserCore: Content {
    var id: String
    var username: String
    var display_name: String
    @NullCoded var bio: String?
    @NullCoded var avatar_url: String?
    @NullCoded var cover_url: String?
    @NullCoded var avatar_color: String?
    @NullCoded var age: Int?
    @NullCoded var location: String?
    @NullCoded var job_title: String?
    @NullCoded var company: String?
    var default_mode: String
    var hobby_setup: Bool
    var work_setup: Bool
    @NullCoded var hobby_theme: String?
    @NullCoded var work_theme: String?
    var follower_count: Int
    var following_count: Int
    var post_count: Int
    var created_at: Date
    var interests: [String]
    var skills: [String]
    /// Hobby-only (migration 062).
    var languages: [String]
    @NullCoded var relationship_status: String?
}

/// `findAll` row — `UserCore` + `mutual_count`, flattened (Node returns one flat
/// object). The same struct decodes the SQL row and encodes the response.
struct SearchUserObject: Content {
    var core: UserCore
    var mutual_count: Int
    init(from decoder: any Decoder) throws {
        core = try UserCore(from: decoder)
        mutual_count = try decoder.container(keyedBy: K.self).decode(Int.self, forKey: .mutual_count)
    }
    func encode(to encoder: any Encoder) throws {
        try core.encode(to: encoder)
        var c = encoder.container(keyedBy: K.self)
        try c.encode(mutual_count, forKey: .mutual_count)
    }
    enum K: String, CodingKey { case mutual_count }
}

/// `findById` row — `UserCore` + `connection_count`, flattened.
struct PublicUserObject: Content {
    var core: UserCore
    var connection_count: Int
    /// Whether this persona's profile links to the person's other one
    /// (`findById` only; the app also checks the other persona is set up).
    var links_other_mode: Bool?
    init(from decoder: any Decoder) throws {
        core = try UserCore(from: decoder)
        let c = try decoder.container(keyedBy: K.self)
        connection_count = try c.decode(Int.self, forKey: .connection_count)
        links_other_mode = try c.decodeIfPresent(Bool.self, forKey: .links_other_mode)
    }
    func encode(to encoder: any Encoder) throws {
        try core.encode(to: encoder)
        var c = encoder.container(keyedBy: K.self)
        try c.encode(connection_count, forKey: .connection_count)
        try c.encodeIfPresent(links_other_mode, forKey: .links_other_mode)
    }
    enum K: String, CodingKey { case connection_count, links_other_mode }
}

/// PATCH /users/me response — `PublicUserObject` + the owner-only fields the
/// controller merges in (`email`, `has_password`, `dob`, `dob_visibility`, `age`).
/// Response-only (never decoded).
struct PrivateUserObject: Content {
    var pub: PublicUserObject
    @NullCoded var email: String?
    var email_verified: Bool
    var has_password: Bool
    @NullCoded var dob: Date?
    @NullCoded var dob_visibility: String?
    @NullCoded var age: Int?
    init(pub: PublicUserObject, email: String?, email_verified: Bool, has_password: Bool, dob: Date?, dob_visibility: String?, age: Int?) {
        self.pub = pub; self._email = .init(wrappedValue: email); self.email_verified = email_verified
        self.has_password = has_password
        self._dob = .init(wrappedValue: dob); self._dob_visibility = .init(wrappedValue: dob_visibility)
        self._age = .init(wrappedValue: age)
    }
    init(from decoder: any Decoder) throws { throw Abort(.internalServerError, reason: "PrivateUserObject is response-only") }
    func encode(to encoder: any Encoder) throws {
        try pub.encode(to: encoder)
        var c = encoder.container(keyedBy: K.self)
        try c.encode(_email, forKey: .email)
        try c.encode(email_verified, forKey: .email_verified)
        try c.encode(has_password, forKey: .has_password)
        try c.encode(_dob, forKey: .dob)
        try c.encode(_dob_visibility, forKey: .dob_visibility)
        try c.encode(_age, forKey: .age)
    }
    enum K: String, CodingKey { case email, email_verified, has_password, dob, dob_visibility, age }
}

struct BlockedUserObject: Content {
    var id: String
    var display_name: String
    @NullCoded var avatar_color: String?
    @NullCoded var avatar_url: String?
    var blocked_at: Date
}

// Small response envelopes.
struct DataResponse<T: Content>: Content { var data: T }
struct DataListResponse<T: Content>: Content { var data: [T] }
struct PaginatedResponse<T: Content>: Content {
    var data: [T]
    var pagination: Pagination
    struct Pagination: Content { var total: Int; var limit: Int; var offset: Int }
}
struct StatusOK: Content { var status = "ok" }
struct BlockedFlagResponse: Content { var status = "ok"; var blocked: Bool }
struct BlockStatusResponse: Content { var blocked: Bool; var blockedEitherWay: Bool }

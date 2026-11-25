import Foundation

// MARK: - Suggestion
/// Someone in "People you may know" (`GET /people/suggestions`), with the one
/// reason the server picked to show on their card.
struct PeopleSuggestion: Identifiable, Decodable, Equatable {
    let id: String
    let username: String
    let displayName: String
    let avatarUrl: String?
    let avatarColor: String?
    let jobTitle: String?
    let company: String?
    let bio: String
    let location: String?
    /// Their interests (Hobby) or skills (Work).
    let tags: [String]
    let mutualCount: Int
    /// Profile-vector similarity × 100, as AI search shows it; nil without an embedding.
    let matchPercent: Int?
    let reason: Reason

    enum Reason: Equatable {
        case mutual(Int)
        case interest(String)
        case skill(String)
        case company(String)
        case place(String)
        case similar
    }

    // MARK: - Decoding
    enum CodingKeys: String, CodingKey {
        case id, username, reason, company, bio, location, tags
        case matchPercent = "match_percent"
        case displayName = "display_name"
        case avatarUrl = "avatar_url"
        case avatarColor = "avatar_color"
        case jobTitle = "job_title"
        case mutualCount = "mutual_count"
    }

    private struct RawReason: Decodable { let kind: String; let value: String?; let count: Int? }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        username = try c.decode(String.self, forKey: .username)
        displayName = try c.decode(String.self, forKey: .displayName)
        avatarUrl = try c.decodeIfPresent(String.self, forKey: .avatarUrl)
        avatarColor = try c.decodeIfPresent(String.self, forKey: .avatarColor)
        jobTitle = try c.decodeIfPresent(String.self, forKey: .jobTitle)
        company = try c.decodeIfPresent(String.self, forKey: .company)
        mutualCount = try c.decodeIfPresent(Int.self, forKey: .mutualCount) ?? 0
        bio = try c.decodeIfPresent(String.self, forKey: .bio) ?? ""
        location = try c.decodeIfPresent(String.self, forKey: .location)
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        matchPercent = try c.decodeIfPresent(Int.self, forKey: .matchPercent)
        let raw = try c.decode(RawReason.self, forKey: .reason)
        // An unknown or incomplete reason still shows the card, just generically.
        switch (raw.kind, raw.value, raw.count) {
        case ("mutual", _, let n?) where n > 0: reason = .mutual(n)
        case ("interest", let v?, _): reason = .interest(v)
        case ("skill", let v?, _): reason = .skill(v)
        case ("company", let v?, _): reason = .company(v)
        case ("place", let v?, _): reason = .place(v)
        default: reason = .similar
        }
    }
}

// MARK: - Profile conversion
extension PeopleSuggestion {
    /// The person as the search cards take them (`FriendSearchCard` /
    /// `ColleagueSearchCard`): their tags land in interests or skills by mode.
    func toUserProfile(mode: AppMode) -> UserProfile {
        UserProfile(
            id: id, name: displayName, username: username,
            avatarColor: avatarColor ?? AppColors.avatarFallback, avatarUrl: avatarUrl,
            bio: bio, jobTitle: jobTitle, company: company,
            skills: mode == .work ? tags : [], interests: mode == .hobby ? tags : [],
            location: location,
            followerCount: 0, followingCount: 0, postCount: 0,
            mutualCount: mutualCount
        )
    }
}

// MARK: - Feed placement
/// Where the "People you may know" module goes in the feed. Pure, so the
/// placement rules are unit-tested.
///
/// - New suggestions you haven't seen → first, above the first post.
/// - Otherwise it waits a few posts in (3–6), so a reload doesn't greet you
///   with the same cards every time.
/// - A second appearance comes 10–13 posts later; never more than two per load.
enum SuggestionPlacement {
    static let maxPerLoad = 2

    /// Indices into the post list the module is shown *before* (an index equal
    /// to `postCount` means after the last post). `seed` supplies the
    /// randomness, fixed per load so the module doesn't jump while you scroll.
    static func slots(isFresh: Bool, postCount: Int, suggestionCount: Int, seed: UInt64) -> [Int] {
        guard suggestionCount > 0, postCount > 0 else { return [] }
        let first = isFresh ? 0 : 3 + Int(seed % 4)
        let second = first + 10 + Int((seed / 4) % 4)
        return [first, second].prefix(maxPerLoad).filter { $0 <= postCount }
    }
}

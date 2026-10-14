import Foundation

/// An open job on the Jobs tab, with how well it fits the signed-in user.
struct JobListing: Identifiable, Decodable, Hashable {
    let id: String
    let postId: String
    let title: String
    let companyName: String?
    let companyId: String?
    let companyLogoUrl: String?
    let companyVerified: Bool
    let location: String?
    let employmentType: String?
    let workFormat: String?
    let level: String?
    let salaryMin: Int?
    let salaryMax: Int?
    let salaryRange: String?
    /// "YYYY-MM-DD".
    let applicationDeadline: String?
    let createdAt: Date
    let description: String?
    let skills: [String]
    var saved: Bool
    var interestedCount: Int
    let poster: Poster
    let isMine: Bool
    let match: Match
    /// Your application's status, once you've applied.
    var applicationStatus: String?
    /// How many applied — for the job's poster or company admins only.
    let applicantCount: Int?

    struct Poster: Decodable, Hashable {
        let id: String
        let displayName: String
        let avatarUrl: String?
        let avatarColor: String?
        let jobTitle: String?
        enum CodingKeys: String, CodingKey {
            case id
            case displayName = "display_name"
            case avatarUrl = "avatar_url"
            case avatarColor = "avatar_color"
            case jobTitle = "job_title"
        }
    }

    struct Match: Decodable, Hashable {
        /// 0…1.
        let score: Double
        let matchedSkills: [String]
        let missingSkills: [String]
        /// skills | company | remote | near | title | profile
        let reason: String
        enum CodingKeys: String, CodingKey {
            case score, reason
            case matchedSkills = "matched_skills"
            case missingSkills = "missing_skills"
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, title, location, level, description, skills, saved, poster, match
        case postId = "post_id"
        case companyName = "company_name"
        case companyId = "company_id"
        case companyLogoUrl = "company_logo_url"
        case companyVerified = "company_verified"
        case employmentType = "employment_type"
        case workFormat = "work_format"
        case salaryMin = "salary_min"
        case salaryMax = "salary_max"
        case salaryRange = "salary_range"
        case applicationDeadline = "application_deadline"
        case createdAt = "created_at"
        case interestedCount = "interested_count"
        case isMine = "is_mine"
        case applicationStatus = "application_status"
        case applicantCount = "applicant_count"
    }

    /// "15–30 million ₫/month", "From 15 million ₫/month", the poster's own
    /// text, or nil (shown as "Negotiable").
    func salaryText(loc: (String) -> String) -> String? {
        switch (salaryMin, salaryMax) {
        case let (lo?, hi?) where lo == hi: return String(format: loc("%lld million ₫/month"), lo)
        case let (lo?, hi?): return String(format: loc("%lld–%lld million ₫/month"), lo, hi)
        case let (lo?, nil): return String(format: loc("From %lld million ₫/month"), lo)
        case let (nil, hi?): return String(format: loc("Up to %lld million ₫/month"), hi)
        default: return salaryRange
        }
    }

    /// The card's reason line: "4 of 6 skills match", "Near you"…
    func matchText(loc: (String) -> String) -> String {
        switch match.reason {
        case "skills": return String(format: loc("%lld of %lld skills match"), match.matchedSkills.count, skills.count)
        case "company": return loc("From a company you follow")
        case "near": return loc("Near you")
        case "remote": return loc("Remote")
        case "title": return loc("Similar to your role")
        default: return loc("Matches your profile")
        }
    }

    var deadlineDate: Date? {
        guard let d = applicationDeadline else { return nil }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        return f.date(from: d)
    }

    static let levels = ["intern", "fresher", "junior", "mid", "senior", "lead", "manager"]
    static func levelLabel(_ level: String) -> String {
        ["intern": "Intern", "fresher": "Fresher", "junior": "Junior", "mid": "Mid-level", "senior": "Senior",
         "lead": "Lead", "manager": "Manager"][level] ?? level.capitalized
    }
    static let formats = ["onsite", "hybrid", "remote"]
    static func formatLabel(_ format: String) -> String {
        ["onsite": "On-site", "hybrid": "Hybrid", "remote": "Remote"][format] ?? format.capitalized
    }
}

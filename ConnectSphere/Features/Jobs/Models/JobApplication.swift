import Foundation

/// An Easy Apply application, as its applicant or the job's managers see it.
struct JobApplication: Identifiable, Decodable, Hashable {
    let id: String
    let jobId: String
    let jobTitle: String
    let companyName: String?
    let companyLogoUrl: String?
    var status: String
    let note: String?
    let cvUrl: String?
    let createdAt: Date
    let events: [Event]
    let applicant: Applicant
    /// How the applicant fits the job (managers' view only).
    let match: JobListing.Match?

    // MARK: - Events & applicant
    struct Event: Decodable, Hashable {
        let status: String
        let createdAt: Date
        enum CodingKeys: String, CodingKey {
            case status
            case createdAt = "created_at"
        }
    }

    struct Applicant: Decodable, Hashable {
        let id: String
        let displayName: String
        let avatarUrl: String?
        let avatarColor: String?
        let jobTitle: String?
        let location: String?
        enum CodingKeys: String, CodingKey {
            case id, location
            case displayName = "display_name"
            case avatarUrl = "avatar_url"
            case avatarColor = "avatar_color"
            case jobTitle = "job_title"
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, status, note, events, applicant, match
        case jobId = "job_id"
        case jobTitle = "job_title"
        case companyName = "company_name"
        case companyLogoUrl = "company_logo_url"
        case cvUrl = "cv_url"
        case createdAt = "created_at"
    }

    // MARK: - Display text
    /// "2 of 3 skills match" for a manager, from the job's own skill list.
    func skillsText(loc: (String) -> String) -> String? {
        guard let match else { return nil }
        let total = match.matchedSkills.count + match.missingSkills.count
        guard total > 0 else { return nil }
        return String(format: loc("%lld of %lld skills match"), match.matchedSkills.count, total)
    }

    static let statuses = ["applied", "viewed", "shortlisted", "rejected", "hired"]

    static func statusLabel(_ status: String) -> String {
        ["applied": "Applied", "viewed": "Viewed", "shortlisted": "Shortlisted",
         "rejected": "Not selected", "hired": "Hired"][status] ?? status.capitalized
    }

    static func statusIcon(_ status: String) -> String {
        ["applied": "paperplane.fill", "viewed": "eye.fill", "shortlisted": "star.fill",
         "rejected": "xmark.circle.fill", "hired": "checkmark.seal.fill"][status] ?? "circle.fill"
    }
}

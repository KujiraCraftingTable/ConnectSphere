import Foundation
import Testing
@testable import ConnectSphere

/// A job as the Jobs tab gets it: pay text and the "why it fits" line.
struct JobListingTests {
    private func job(min: Int? = 15, max: Int? = 30, range: String? = nil, reason: String = "skills",
                     matched: [String] = ["Swift"], skills: [String] = ["Swift", "Kotlin"]) throws -> JobListing {
        func n(_ v: Int?) -> String { v.map(String.init) ?? "null" }
        let json = """
        {"id":"j1","post_id":"p1","title":"iOS Engineer","company_name":"Acme","company_id":null,"company_logo_url":null,
         "company_verified":true,"location":"Hanoi","employment_type":"full_time","work_format":"hybrid","level":"senior",
         "salary_min":\(n(min)),"salary_max":\(n(max)),"salary_range":\(range.map { "\"\($0)\"" } ?? "null"),
         "application_deadline":"2026-12-31","created_at":"2026-10-14T09:00:00.000Z","description":"Build apps",
         "skills":\(String(data: try JSONEncoder().encode(skills), encoding: .utf8)!),"saved":false,"interested_count":2,
         "poster":{"id":"u1","display_name":"An","avatar_url":null,"avatar_color":null,"job_title":"CTO"},"is_mine":false,
         "match":{"score":0.7,"matched_skills":\(String(data: try JSONEncoder().encode(matched), encoding: .utf8)!),"missing_skills":["Kotlin"],"reason":"\(reason)"}}
        """
        return try JSONDecoder.makeISO8601().decode(JobListing.self, from: Data(json.utf8))
    }

    private let loc = { (s: String) in s }

    @Test func decodesAJob() throws {
        let j = try job()
        #expect(j.companyVerified && j.level == "senior" && j.poster.jobTitle == "CTO")
        #expect(j.deadlineDate != nil)
    }

    @Test func payReadsAsARange() throws {
        #expect(try job().salaryText(loc: loc) == "15–30 million ₫/month")
        #expect(try job(min: 20, max: nil).salaryText(loc: loc) == "From 20 million ₫/month")
        #expect(try job(min: nil, max: 40).salaryText(loc: loc) == "Up to 40 million ₫/month")
        #expect(try job(min: nil, max: nil, range: "Competitive").salaryText(loc: loc) == "Competitive")
        #expect(try job(min: nil, max: nil).salaryText(loc: loc) == nil)
    }

    @Test func reasonLine() throws {
        #expect(try job().matchText(loc: loc) == "1 of 2 skills match")
        #expect(try job(reason: "company").matchText(loc: loc) == "From a company you follow")
        #expect(try job(reason: "near").matchText(loc: loc) == "Near you")
        #expect(try job(reason: "profile").matchText(loc: loc) == "Matches your profile")
    }
}

/// An Easy Apply application as the app gets it.
struct JobApplicationTests {
    private func application(match: String = #"{"score":0.6,"matched_skills":["Figma"],"missing_skills":["Sketch","UX"],"reason":"skills"}"#) throws -> JobApplication {
        let json = """
        {"id":"a1","job_id":"j1","job_title":"Designer","company_name":"Acme","company_logo_url":null,"status":"shortlisted",
         "note":"Hi","cv_url":"/uploads/cv/u_x.pdf","created_at":"2026-10-14T09:00:00.000Z","updated_at":"2026-10-14T10:00:00.000Z",
         "events":[{"status":"applied","created_at":"2026-10-14T09:00:00.000Z"},{"status":"shortlisted","created_at":"2026-10-14T10:00:00.000Z"}],
         "applicant":{"id":"u","display_name":"Bao","avatar_url":null,"avatar_color":"#123456","job_title":"UI designer","location":null},
         "match":\(match)}
        """
        return try JSONDecoder.makeISO8601().decode(JobApplication.self, from: Data(json.utf8))
    }

    @Test func decodesTheTimeline() throws {
        let a = try application()
        #expect(a.events.map(\.status) == ["applied", "shortlisted"])
        #expect(a.applicant.displayName == "Bao" && a.cvUrl != nil)
    }

    @Test func skillFitCountsTheJobsSkills() throws {
        #expect(try application().skillsText(loc: { $0 }) == "1 of 3 skills match")
        #expect(try application(match: "null").skillsText(loc: { $0 }) == nil)
    }

    @Test func statusLabels() {
        #expect(JobApplication.statusLabel("rejected") == "Not selected")
        #expect(JobApplication.statuses.allSatisfy { JobApplication.statusIcon($0) != "circle.fill" })
    }
}
